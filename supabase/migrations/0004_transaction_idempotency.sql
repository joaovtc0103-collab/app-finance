-- Idempotency key prevents duplicate submissions from retries/double requests.
alter table public.financial_transactions
  add column if not exists idempotency_key uuid;

update public.financial_transactions
set idempotency_key = gen_random_uuid()
where idempotency_key is null;

alter table public.financial_transactions
  alter column idempotency_key set default gen_random_uuid(),
  alter column idempotency_key set not null;

create unique index if not exists financial_transactions_owner_idempotency_uidx
  on public.financial_transactions(owner_id, idempotency_key);
