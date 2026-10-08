-- ============================================================
-- VERITAS: Automated AP Audit Gateway  |  Supabase schema
-- Paste the whole file into Supabase > SQL Editor > Run
-- ============================================================

-- ---------- TABLES ----------
create table if not exists vendors (
  vendor_name         text primary key,
  total_transactions  int           not null default 0,
  avg_invoice_amount  numeric(14,2) not null default 0,
  risk_history        jsonb         not null default '[]'::jsonb  -- array of past risk scores, newest last
);

create table if not exists invoices (
  id            uuid primary key default gen_random_uuid(),
  invoice_id    text          not null,                 -- NOT unique on purpose: duplicates are stored as Blocked
  vendor_name   text          not null,
  amount        numeric(14,2) not null check (amount >= 0),
  tax_rate      numeric(5,2)  not null default 0,
  status        text          not null default 'Review'
                check (status in ('Approved','Flagged','Blocked','Review')),
  risk_score    int           not null default 0 check (risk_score between 0 and 100),
  file_name     text,
  file_hash     text,
  risk_reasons  jsonb         not null default '[]'::jsonb,
  created_at    timestamptz   not null default now()
);
create index if not exists idx_invoices_invoice_id on invoices (invoice_id);
create index if not exists idx_invoices_vendor_amt on invoices (vendor_name, amount, created_at);

create table if not exists audit_logs (
  id         bigint generated always as identity primary key,
  "timestamp" timestamptz not null default now(),
  log_level  text not null default 'INFO' check (log_level in ('INFO','WARN','ALERT')),
  message    text not null
);

-- ---------- RISK ENGINE + PROCESSING (call via supabase.rpc) ----------
create or replace function process_invoice(
  p_invoice_id  text,
  p_vendor_name text,
  p_amount      numeric,
  p_tax_rate    numeric,
  p_file_name   text default null,
  p_file_hash   text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v          vendors%rowtype;
  score      int := 0;
  reasons    jsonb := '[]'::jsonb;
  new_status text;
  dup_id     boolean;
  dup_amount boolean;
  dup_file   boolean := false;
  inv_row    invoices%rowtype;
begin
  insert into audit_logs(log_level, message)
  values ('INFO', format('Document received: %s', coalesce(p_file_name, p_invoice_id)));

  select * into v from vendors where vendor_name = p_vendor_name;

  insert into audit_logs(log_level, message)
  values ('INFO', format('OCR extraction complete: %s | %s | %s', p_invoice_id, p_vendor_name, p_amount));

  -- RULE 1: same invoice number already processed (hard duplicate)
  select exists(select 1 from invoices where invoice_id = p_invoice_id) into dup_id;
  if dup_id then
    score := score + 60;
    reasons := reasons || to_jsonb('Duplicate invoice number'::text);
  end if;

  -- RULE 2: same file hash re-uploaded
  if p_file_hash is not null then
    select exists(select 1 from invoices where file_hash = p_file_hash) into dup_file;
    if dup_file then
      score := score + 30;
      reasons := reasons || to_jsonb('Identical file re-uploaded'::text);
    end if;
  end if;

  -- RULE 3: same vendor + same amount within 30 days (likely re-billing)
  select exists(
    select 1 from invoices
    where vendor_name = p_vendor_name and amount = p_amount
      and created_at > now() - interval '30 days'
      and invoice_id <> p_invoice_id
  ) into dup_amount;
  if dup_amount then
    score := score + 40;
    reasons := reasons || to_jsonb('Same vendor and amount within 30 days'::text);
  end if;

  -- RULE 4: amount far above this vendor's average
  if v.vendor_name is not null and v.total_transactions >= 3
     and v.avg_invoice_amount > 0 and p_amount > v.avg_invoice_amount * 3 then
    score := score + 25;
    reasons := reasons || to_jsonb('Amount exceeds 3x vendor average'::text);
  end if;

  -- RULE 5: large absolute amount
  if p_amount > 100000 then
    score := score + 15;
    reasons := reasons || to_jsonb('High-value invoice (>100,000)'::text);
  end if;

  -- RULE 6: non-standard tax slab (0/5/12/18/28)
  if p_tax_rate not in (0,5,12,18,28) then
    score := score + 20;
    reasons := reasons || to_jsonb(format('Non-standard tax rate (%s%%)', p_tax_rate));
  end if;

  -- RULE 7: unknown vendor
  if v.vendor_name is null then
    score := score + 10;
    reasons := reasons || to_jsonb('New / unverified vendor'::text);
  end if;

  -- RULE 8: suspiciously round amount
  if p_amount >= 10000 and p_amount = round(p_amount, -3) then
    score := score + 5;
    reasons := reasons || to_jsonb('Round-figure amount'::text);
  end if;

  score := least(score, 100);

  new_status := case
    when dup_id or score >= 85 then 'Blocked'
    when score >= 60 then 'Flagged'
    when score >= 35 then 'Review'
    else 'Approved'
  end;

  insert into invoices(invoice_id, vendor_name, amount, tax_rate, status, risk_score, file_name, file_hash, risk_reasons)
  values (p_invoice_id, p_vendor_name, p_amount, p_tax_rate, new_status, score, p_file_name, p_file_hash, reasons)
  returning * into inv_row;

  -- update vendor stats (skip hard duplicates so averages stay clean)
  if not dup_id then
    insert into vendors(vendor_name, total_transactions, avg_invoice_amount, risk_history)
    values (p_vendor_name, 1, p_amount, jsonb_build_array(score))
    on conflict (vendor_name) do update set
      avg_invoice_amount = round(
        (vendors.avg_invoice_amount * vendors.total_transactions + p_amount) / (vendors.total_transactions + 1), 2),
      total_transactions = vendors.total_transactions + 1,
      risk_history       = vendors.risk_history || to_jsonb(score);
  end if;

  insert into audit_logs(log_level, message)
  values (
    case new_status when 'Blocked' then 'ALERT' when 'Approved' then 'INFO' else 'WARN' end,
    format('%s scored %s/100 -> %s%s', p_invoice_id, score, upper(new_status),
           case when jsonb_array_length(reasons) > 0
                then ' | ' || (select string_agg(r, '; ') from jsonb_array_elements_text(reasons) r)
                else '' end)
  );

  return jsonb_build_object(
    'id', inv_row.id, 'invoice_id', p_invoice_id, 'vendor_name', p_vendor_name,
    'amount', p_amount, 'tax_rate', p_tax_rate,
    'status', new_status, 'risk_score', score, 'reasons', reasons
  );
end $$;

-- ---------- KPI VIEW (feeds the bento grid) ----------
create or replace view kpi_summary as
select
  coalesce(sum(amount), 0)                                          as total_scanned_volume,
  coalesce(sum(amount) filter (where status = 'Blocked'), 0)        as fraud_prevented,
  count(*) filter (where status in ('Flagged','Review'))            as pending_risk_flags,
  count(*)                                                          as total_invoices
from invoices;

-- ---------- DEMO HELPER ----------
create or replace function reset_demo() returns void
language sql security definer set search_path = public as $$
  truncate invoices, vendors, audit_logs restart identity;
$$;

-- ---------- SECURITY (hackathon mode: public read, writes only through functions) ----------
alter table invoices   enable row level security;
alter table vendors    enable row level security;
alter table audit_logs enable row level security;

drop policy if exists "read invoices"   on invoices;
drop policy if exists "read vendors"    on vendors;
drop policy if exists "read audit_logs" on audit_logs;
create policy "read invoices"   on invoices   for select using (true);
create policy "read vendors"    on vendors    for select using (true);
create policy "read audit_logs" on audit_logs for select using (true);

grant select on invoices, vendors, audit_logs, kpi_summary to anon, authenticated;
grant execute on function process_invoice(text,text,numeric,numeric,text,text) to anon, authenticated;
grant execute on function reset_demo() to anon, authenticated;

-- ---------- REALTIME (live audit trail + live table) ----------
alter publication supabase_realtime add table invoices;
alter publication supabase_realtime add table audit_logs;

-- ---------- SEED DATA (so the dashboard isn't empty) ----------
insert into vendors(vendor_name, total_transactions, avg_invoice_amount, risk_history) values
  ('Acme Industrial Supplies', 14, 18500, '[10,12,8,15,20]'),
  ('Globex Logistics',          9, 42000, '[22,18,30,25]'),
  ('Initech Software',         21,  9800, '[5,8,6,7]'),
  ('Umbrella Chemicals',        4, 76000, '[45,60,52]')
on conflict do nothing;

insert into invoices(invoice_id, vendor_name, amount, tax_rate, status, risk_score, risk_reasons, created_at) values
  ('INV-10021','Acme Industrial Supplies', 17250.00, 18, 'Approved',  8, '[]',                                              now() - interval '3 days'),
  ('INV-10022','Globex Logistics',         44800.00, 18, 'Approved', 14, '[]',                                              now() - interval '2 days'),
  ('INV-10023','Initech Software',          9900.00, 18, 'Approved',  6, '[]',                                              now() - interval '2 days'),
  ('INV-10024','Umbrella Chemicals',      240000.00, 14, 'Blocked',  92, '["High-value invoice (>100,000)","Non-standard tax rate (14%)","Amount exceeds 3x vendor average"]', now() - interval '1 day'),
  ('INV-10025','Globex Logistics',         44800.00, 18, 'Flagged',  65, '["Same vendor and amount within 30 days"]',      now() - interval '1 day'),
  ('INV-10026','Acme Industrial Supplies', 52000.00, 12, 'Review',   40, '["Amount exceeds 3x vendor average"]',           now() - interval '5 hours');

insert into audit_logs(log_level, message) values
  ('INFO',  'Veritas gateway online. Rule engine v1 loaded.'),
  ('INFO',  'INV-10021 scored 8/100 -> APPROVED'),
  ('ALERT', 'INV-10024 scored 92/100 -> BLOCKED | High-value invoice; Non-standard tax rate (14%)'),
  ('WARN',  'INV-10025 scored 65/100 -> FLAGGED | Same vendor and amount within 30 days');
