-- Finance ledger integrity hardening and safe migration of existing posted rows.
create or replace function public.apply_transaction_to_ledger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_entry_type text;
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
      if old.status = 'posted' and new.status not in ('posted','reversed') then
        raise exception 'Lançamento confirmado só pode ser estornado.';
      end if;
    end if;
  end if;

  if new.kind in ('transfer_in','transfer_out') then
    if new.transfer_id is null then raise exception 'Movimentações de transferência devem pertencer a uma transferência vinculada.'; end if;
  elsif new.transfer_id is not null then
    raise exception 'Somente movimentações de transferência podem referenciar uma transferência.';
  end if;

  if new.status = 'posted' and (tg_op = 'INSERT' or old.status <> 'posted') then
    if new.account_id is null then raise exception 'Selecione uma conta para confirmar a movimentação.'; end if;
    if new.kind in ('income','transfer_in') or (new.kind = 'adjustment' and new.adjustment_effect = 'increase') then
      v_entry_type := 'debit';
    elsif new.kind in ('expense','transfer_out') or (new.kind = 'adjustment' and new.adjustment_effect = 'decrease') then
      v_entry_type := 'credit';
    else
      raise exception 'Tipo de movimentação não suportado pelo ledger.';
    end if;
    insert into public.ledger_entries(owner_id, transaction_id, account_id, entry_type, amount, entry_role, occurred_at)
    values (new.owner_id, new.id, new.account_id, v_entry_type, new.amount, 'original', new.occurred_at)
    on conflict (transaction_id, entry_role) do nothing;
  elsif tg_op = 'UPDATE' and old.status = 'posted' and new.status = 'reversed' then
    select case entry_type when 'debit' then 'credit' else 'debit' end into v_entry_type
    from public.ledger_entries where transaction_id = old.id and entry_role = 'original';
    if v_entry_type is null then raise exception 'Não foi encontrado o lançamento contábil original para estorno.'; end if;
    insert into public.ledger_entries(owner_id, transaction_id, account_id, entry_type, amount, entry_role, occurred_at)
    values (old.owner_id, old.id, old.account_id, v_entry_type, old.amount, 'reversal', now())
    on conflict (transaction_id, entry_role) do nothing;
  end if;
  return new;
end;
$$;

-- Existing posted income/expense/adjustment rows are migrated into the ledger once.
insert into public.ledger_entries(owner_id, transaction_id, account_id, entry_type, amount, entry_role, occurred_at)
select t.owner_id, t.id, t.account_id,
  case
    when t.kind = 'income' then 'debit'
    when t.kind = 'expense' then 'credit'
    when t.kind = 'adjustment' and t.adjustment_effect = 'increase' then 'debit'
    when t.kind = 'adjustment' and t.adjustment_effect = 'decrease' then 'credit'
  end,
  t.amount, 'original', t.occurred_at
from public.financial_transactions t
where t.status = 'posted'
  and t.account_id is not null
  and t.kind in ('income','expense','adjustment')
on conflict (transaction_id, entry_role) do nothing;

-- Deferred check ensures a transfer cannot commit with only one side.
create or replace function public.assert_transfer_has_two_legs()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_count integer; v_out integer; v_in integer;
begin
  v_id := coalesce(new.transfer_id, old.transfer_id);
  if v_id is null then return null; end if;
  select count(*),
         count(*) filter (where kind = 'transfer_out'),
         count(*) filter (where kind = 'transfer_in')
    into v_count, v_out, v_in
    from public.financial_transactions
   where transfer_id = v_id and status <> 'cancelled';
  if v_count <> 2 or v_out <> 1 or v_in <> 1 then
    raise exception 'Transferência precisa conter exatamente uma saída e uma entrada vinculadas.';
  end if;
  return null;
end;
$$;
drop trigger if exists transfer_must_have_two_legs on public.financial_transactions;
create constraint trigger transfer_must_have_two_legs
after insert or update or delete on public.financial_transactions
deferrable initially deferred
for each row execute function public.assert_transfer_has_two_legs();
