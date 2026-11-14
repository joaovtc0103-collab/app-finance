-- Finance ledger v2: append-only accounting events, safe transfers and derived balances.
-- This migration is intentionally additive and can be reapplied safely.

alter table public.financial_transactions
  add column if not exists transfer_id uuid,
  add column if not exists adjustment_effect text;

alter table public.ledger_entries
  add column if not exists entry_role text not null default 'original',
  add column if not exists occurred_at timestamptz not null default now();

do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'financial_transactions_transfer_id_fkey') then
    alter table public.financial_transactions
      add constraint financial_transactions_transfer_id_fkey
      foreign key (transfer_id) references public.transfers(id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'financial_transactions_adjustment_effect_check') then
    alter table public.financial_transactions
      add constraint financial_transactions_adjustment_effect_check
      check (kind <> 'adjustment' or adjustment_effect in ('increase','decrease'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'ledger_entries_entry_role_check') then
    alter table public.ledger_entries
      add constraint ledger_entries_entry_role_check
      check (entry_role in ('original','reversal'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'financial_accounts_id_owner_key') then
    alter table public.financial_accounts add constraint financial_accounts_id_owner_key unique(id, owner_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'categories_id_owner_key') then
    alter table public.categories add constraint categories_id_owner_key unique(id, owner_id);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'financial_transactions_account_owner_fkey') then
    alter table public.financial_transactions
      add constraint financial_transactions_account_owner_fkey
      foreign key (account_id, owner_id)
      references public.financial_accounts(id, owner_id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'financial_transactions_category_owner_fkey') then
    alter table public.financial_transactions
      add constraint financial_transactions_category_owner_fkey
      foreign key (category_id, owner_id)
      references public.categories(id, owner_id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'transfers_from_account_owner_fkey') then
    alter table public.transfers
      add constraint transfers_from_account_owner_fkey
      foreign key (from_account_id, owner_id)
      references public.financial_accounts(id, owner_id) on delete restrict;
  end if;
  if not exists (select 1 from pg_constraint where conname = 'transfers_to_account_owner_fkey') then
    alter table public.transfers
      add constraint transfers_to_account_owner_fkey
      foreign key (to_account_id, owner_id)
      references public.financial_accounts(id, owner_id) on delete restrict;
  end if;
end $$;

create unique index if not exists ledger_entries_transaction_role_uidx
  on public.ledger_entries(transaction_id, entry_role);
create unique index if not exists financial_transactions_transfer_kind_uidx
  on public.financial_transactions(transfer_id, kind)
  where transfer_id is not null;
create index if not exists ledger_entries_owner_account_time_idx
  on public.ledger_entries(owner_id, account_id, occurred_at desc);

-- A transaction can only post once. A later reversal is a separate, immutable ledger row.
create or replace function public.apply_transaction_to_ledger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_entry_type text;
begin
  if tg_op = 'UPDATE' then
    if old.status in ('posted','reversed') then
      if (new.owner_id, new.amount, new.kind, new.account_id, new.occurred_at, new.transfer_id, new.adjustment_effect)
         is distinct from
         (old.owner_id, old.amount, old.kind, old.account_id, old.occurred_at, old.transfer_id, old.adjustment_effect) then
        raise exception 'Lançamento confirmado é imutável; registre um estorno para corrigir.';
      end if;
      if old.status = 'reversed' and new.status <> 'reversed' then
        raise exception 'Um lançamento estornado não pode ser reativado.';
      end if;
    end if;
  end if;

  if new.kind in ('transfer_in','transfer_out') then
    if new.transfer_id is null then
      raise exception 'Movimentações de transferência devem pertencer a uma transferência vinculada.';
    end if;
  elsif new.transfer_id is not null then
    raise exception 'Somente movimentações de transferência podem referenciar uma transferência.';
  end if;

  if new.status = 'posted' and (tg_op = 'INSERT' or old.status <> 'posted') then
    if new.account_id is null then
      raise exception 'Selecione uma conta para confirmar a movimentação.';
    end if;
    if new.kind in ('income','transfer_in') then
      v_entry_type := 'debit';
    elsif new.kind in ('expense','transfer_out') then
      v_entry_type := 'credit';
    elsif new.kind = 'adjustment' and new.adjustment_effect = 'increase' then
      v_entry_type := 'debit';
    elsif new.kind = 'adjustment' and new.adjustment_effect = 'decrease' then
      v_entry_type := 'credit';
    else
      raise exception 'Tipo de movimentação não suportado pelo ledger.';
    end if;

    insert into public.ledger_entries(owner_id, transaction_id, account_id, entry_type, amount, entry_role, occurred_at)
    values (new.owner_id, new.id, new.account_id, v_entry_type, new.amount, 'original', new.occurred_at)
    on conflict (transaction_id, entry_role) do nothing;
  elsif tg_op = 'UPDATE' and old.status = 'posted' and new.status = 'reversed' then
    select case entry_type when 'debit' then 'credit' else 'debit' end
      into v_entry_type
      from public.ledger_entries
      where transaction_id = old.id and entry_role = 'original';

    if v_entry_type is null then
      raise exception 'Não foi encontrado o lançamento contábil original para estorno.';
    end if;

    insert into public.ledger_entries(owner_id, transaction_id, account_id, entry_type, amount, entry_role, occurred_at)
    values (old.owner_id, old.id, old.account_id, v_entry_type, old.amount, 'reversal', now())
    on conflict (transaction_id, entry_role) do nothing;
  end if;

  return new;
end;
$$;

drop trigger if exists financial_transaction_ledger_after_write on public.financial_transactions;
create trigger financial_transaction_ledger_after_write
after insert or update of status, owner_id, amount, kind, account_id, occurred_at, transfer_id, adjustment_effect
on public.financial_transactions
for each row execute function public.apply_transaction_to_ledger();

create or replace function public.prevent_posted_transaction_delete()
returns trigger
language plpgsql
as $$
begin
  if old.status in ('posted','reversed') then
    raise exception 'Lançamentos confirmados não podem ser excluídos; use estorno.';
  end if;
  return old;
end;
$$;
drop trigger if exists prevent_posted_transaction_delete on public.financial_transactions;
create trigger prevent_posted_transaction_delete
before delete on public.financial_transactions
for each row execute function public.prevent_posted_transaction_delete();

-- Validate transfer legs against the parent transfer and its account ownership.
create or replace function public.validate_transfer_leg()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  t public.transfers%rowtype;
begin
  if new.transfer_id is null then return new; end if;
  select * into t from public.transfers where id = new.transfer_id;
  if not found or t.owner_id <> new.owner_id or t.amount <> new.amount then
    raise exception 'Transferência inválida ou pertencente a outro usuário.';
  end if;
  if new.kind = 'transfer_out' and new.account_id <> t.from_account_id then
    raise exception 'Conta de origem não corresponde à transferência.';
  elsif new.kind = 'transfer_in' and new.account_id <> t.to_account_id then
    raise exception 'Conta de destino não corresponde à transferência.';
  end if;
  return new;
end;
$$;
drop trigger if exists validate_transfer_leg on public.financial_transactions;
create trigger validate_transfer_leg
before insert or update on public.financial_transactions
for each row execute function public.validate_transfer_leg();

-- One atomic RPC creates the transfer and both accounting legs.
create or replace function public.create_transfer(
  p_from_account_id uuid,
  p_to_account_id uuid,
  p_amount numeric,
  p_occurred_at timestamptz default now(),
  p_description text default 'Transferência entre contas'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_transfer_id uuid;
begin
  if v_user is null then raise exception 'Autenticação obrigatória.'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'Informe um valor positivo com até duas casas decimais.';
  end if;
  if p_from_account_id = p_to_account_id then
    raise exception 'As contas de origem e destino devem ser diferentes.';
  end if;
  if not exists(select 1 from public.financial_accounts where id = p_from_account_id and owner_id = v_user and is_active)
     or not exists(select 1 from public.financial_accounts where id = p_to_account_id and owner_id = v_user and is_active) then
    raise exception 'As duas contas devem pertencer ao usuário e estar ativas.';
  end if;
  if (select currency from public.financial_accounts where id = p_from_account_id) <>
     (select currency from public.financial_accounts where id = p_to_account_id) then
    raise exception 'Transferências entre moedas diferentes ainda não são suportadas.';
  end if;

  insert into public.transfers(owner_id, from_account_id, to_account_id, amount, occurred_at, description)
  values (v_user, p_from_account_id, p_to_account_id, p_amount, coalesce(p_occurred_at, now()), nullif(trim(p_description), ''))
  returning id into v_transfer_id;

  insert into public.financial_transactions(owner_id, description, amount, currency, kind, status, account_id, occurred_at, transfer_id, visibility)
  select v_user, coalesce(nullif(trim(p_description), ''), 'Transferência entre contas'), p_amount, a.currency,
         'transfer_out', 'posted', p_from_account_id, coalesce(p_occurred_at, now()), v_transfer_id, 'private'
    from public.financial_accounts a where a.id = p_from_account_id;

  insert into public.financial_transactions(owner_id, description, amount, currency, kind, status, account_id, occurred_at, transfer_id, visibility)
  select v_user, coalesce(nullif(trim(p_description), ''), 'Transferência entre contas'), p_amount, a.currency,
         'transfer_in', 'posted', p_to_account_id, coalesce(p_occurred_at, now()), v_transfer_id, 'private'
    from public.financial_accounts a where a.id = p_to_account_id;

  return v_transfer_id;
end;
$$;

-- The balance is derived from opening balance plus immutable ledger movements.
create or replace view public.account_balances
with (security_invoker = true)
as
select
  a.id as account_id,
  a.owner_id,
  a.name,
  a.account_type,
  a.currency,
  a.opening_balance,
  a.opening_balance_date,
  a.is_active,
  a.opening_balance + coalesce(sum(
    case
      when le.entry_type = 'debit' then le.amount
      when le.entry_type = 'credit' then -le.amount
      else 0
    end
  ), 0) as current_balance
from public.financial_accounts a
left join public.ledger_entries le
  on le.account_id = a.id
 and le.owner_id = a.owner_id
 and le.occurred_at >= a.opening_balance_date::timestamptz
group by a.id;

alter table public.ledger_entries enable row level security;
drop policy if exists "ledger owner only" on public.ledger_entries;
create policy "ledger owner read" on public.ledger_entries for select using (owner_id = auth.uid());

-- Ledger writes are only performed by the SECURITY DEFINER transaction trigger.
revoke insert, update, delete on public.ledger_entries from authenticated;
revoke insert, update, delete on public.transfers from authenticated;
grant select on public.ledger_entries to authenticated;
grant select on public.account_balances to authenticated;
grant execute on function public.create_transfer(uuid, uuid, numeric, timestamptz, text) to authenticated;
