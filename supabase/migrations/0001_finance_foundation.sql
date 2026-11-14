-- Finance foundation: private-first personal finance model.
create extension if not exists pgcrypto;

create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end;
$$;

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text,
  locale text not null default 'pt-BR',
  currency char(3) not null default 'BRL',
  timezone text not null default 'America/Fortaleza',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.shared_workspaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete restrict,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.workspace_members (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.shared_workspaces(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null check (role in ('owner','admin','collaborator','viewer')),
  created_at timestamptz not null default now(),
  unique(workspace_id,user_id)
);

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  kind text not null check (kind in ('income','expense')),
  icon text,
  color text,
  is_system boolean not null default false,
  created_at timestamptz not null default now(),
  unique(owner_id, name, kind)
);

create table public.financial_accounts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  institution text,
  account_type text not null check (account_type in ('checking','savings','digital_wallet','cash','benefit','investment','other')),
  opening_balance numeric(18,2) not null default 0,
  opening_balance_date date not null default current_date,
  currency char(3) not null default 'BRL',
  color text,
  icon text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(id,owner_id)
);

create table public.financial_transactions (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  workspace_id uuid references public.shared_workspaces(id) on delete restrict,
  visibility text not null default 'private' check (visibility in ('private','shared')),
  description text not null check (length(trim(description)) > 0),
  amount numeric(18,2) not null check (amount > 0),
  currency char(3) not null default 'BRL',
  kind text not null check (kind in ('income','expense','transfer_in','transfer_out','adjustment')),
  status text not null default 'posted' check (status in ('pending','posted','cancelled','reversed')),
  category_id uuid references public.categories(id) on delete set null,
  account_id uuid references public.financial_accounts(id) on delete restrict,
  occurred_at timestamptz not null default now(),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((visibility = 'private' and workspace_id is null) or (visibility = 'shared' and workspace_id is not null))
);

create table public.transfers (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  from_account_id uuid not null references public.financial_accounts(id) on delete restrict,
  to_account_id uuid not null references public.financial_accounts(id) on delete restrict,
  amount numeric(18,2) not null check (amount > 0),
  occurred_at timestamptz not null default now(),
  description text,
  created_at timestamptz not null default now(),
  check (from_account_id <> to_account_id)
);

create table public.ledger_entries (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  transaction_id uuid not null references public.financial_transactions(id) on delete restrict,
  account_id uuid not null references public.financial_accounts(id) on delete restrict,
  entry_type text not null check (entry_type in ('debit','credit')),
  amount numeric(18,2) not null check (amount > 0),
  created_at timestamptz not null default now()
);

create index financial_transactions_owner_date_idx on public.financial_transactions(owner_id, occurred_at desc);
create index financial_transactions_workspace_date_idx on public.financial_transactions(workspace_id, occurred_at desc) where workspace_id is not null;
create index financial_transactions_account_date_idx on public.financial_transactions(account_id, occurred_at desc);
create index ledger_entries_account_idx on public.ledger_entries(account_id, created_at desc);
create index workspace_members_user_idx on public.workspace_members(user_id, workspace_id);

create trigger profiles_updated_at before update on public.profiles for each row execute function public.set_updated_at();
create trigger workspaces_updated_at before update on public.shared_workspaces for each row execute function public.set_updated_at();
create trigger accounts_updated_at before update on public.financial_accounts for each row execute function public.set_updated_at();
create trigger transactions_updated_at before update on public.financial_transactions for each row execute function public.set_updated_at();

-- A newly registered user gets a profile and a private personal workspace.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, display_name) values (new.id, coalesce(new.raw_user_meta_data->>'name',''));
  return new;
end;
$$;
create trigger on_auth_user_created after insert on auth.users for each row execute procedure public.handle_new_user();

create or replace function public.is_workspace_member(target_workspace uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.shared_workspaces w where w.id = target_workspace and w.owner_id = auth.uid())
    or exists(select 1 from public.workspace_members m where m.workspace_id = target_workspace and m.user_id = auth.uid());
$$;

alter table public.profiles enable row level security;
alter table public.shared_workspaces enable row level security;
alter table public.workspace_members enable row level security;
alter table public.categories enable row level security;
alter table public.financial_accounts enable row level security;
alter table public.financial_transactions enable row level security;
alter table public.transfers enable row level security;
alter table public.ledger_entries enable row level security;

create policy "profile owner access" on public.profiles for all using (id = auth.uid()) with check (id = auth.uid());
create policy "workspace members read" on public.shared_workspaces for select using (owner_id = auth.uid() or public.is_workspace_member(id));
create policy "workspace owner manage" on public.shared_workspaces for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "members read workspace roster" on public.workspace_members for select using (user_id = auth.uid() or public.is_workspace_member(workspace_id));
create policy "workspace owner manages members" on public.workspace_members for all using (exists(select 1 from public.shared_workspaces w where w.id = workspace_id and w.owner_id = auth.uid())) with check (exists(select 1 from public.shared_workspaces w where w.id = workspace_id and w.owner_id = auth.uid()));
create policy "category owner only" on public.categories for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "account owner only" on public.financial_accounts for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "transaction private or workspace member" on public.financial_transactions for select using (
  (visibility = 'private' and owner_id = auth.uid()) or
  (visibility = 'shared' and public.is_workspace_member(workspace_id))
);
create policy "transaction insert own or shared workspace" on public.financial_transactions for insert with check (
  owner_id = auth.uid() and (
    (visibility = 'private' and workspace_id is null) or
    (visibility = 'shared' and public.is_workspace_member(workspace_id))
  )
);
create policy "transaction owner update" on public.financial_transactions for update using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "transaction owner delete" on public.financial_transactions for delete using (owner_id = auth.uid());
create policy "transfer owner only" on public.transfers for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy "ledger owner only" on public.ledger_entries for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Guard account/category references against cross-user assignment.
create or replace function public.validate_transaction_ownership()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.account_id is not null and not exists (
    select 1 from public.financial_accounts a where a.id = new.account_id and a.owner_id = new.owner_id
  ) then raise exception 'Conta não pertence ao usuário.'; end if;
  if new.category_id is not null and not exists (
    select 1 from public.categories c where c.id = new.category_id and c.owner_id = new.owner_id
  ) then raise exception 'Categoria não pertence ao usuário.'; end if;
  if new.visibility = 'shared' and not public.is_workspace_member(new.workspace_id) then
    raise exception 'Usuário não participa deste espaço compartilhado.';
  end if;
  return new;
end;
$$;
create trigger validate_transaction_ownership before insert or update on public.financial_transactions
for each row execute function public.validate_transaction_ownership();

-- Restrict browser privileges to authenticated users; RLS remains the authorization boundary.
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.profiles, public.shared_workspaces, public.workspace_members,
  public.categories, public.financial_accounts, public.financial_transactions, public.transfers, public.ledger_entries to authenticated;
