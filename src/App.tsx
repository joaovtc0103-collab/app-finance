import { useEffect, useMemo, useState } from 'react'
import type { FormEvent } from 'react'
import type { Session } from '@supabase/supabase-js'
import { ArrowDownLeft, ArrowUpRight, Banknote, Bell, CalendarDays, ChartNoAxesCombined, CircleHelp, CreditCard, LayoutDashboard, LogOut, Plus, Receipt, Settings, ShieldCheck, Wallet } from 'lucide-react'
import { supabase, isSupabaseConfigured } from './lib/supabase'

type Account = { account_id: string; name: string; current_balance: number }

type Transaction = {
  id: string
  description: string
  amount: number
  kind: 'income' | 'expense'
  occurred_at: string
  status: string
  category?: { name: string } | null
  account?: { name: string } | null
}

const money = (value: number) => new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(value)
const dateLabel = new Intl.DateTimeFormat('pt-BR', { day: '2-digit', month: 'short' })

export default function App() {
  const [session, setSession] = useState<Session | null>(null)
  const [loading, setLoading] = useState(true)
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [authMessage, setAuthMessage] = useState('')
  const [transactions, setTransactions] = useState<Transaction[]>([])
  const [accounts, setAccounts] = useState<Account[]>([])
  const [accountId, setAccountId] = useState('')
  const [showForm, setShowForm] = useState(false)
  const [description, setDescription] = useState('')
  const [amount, setAmount] = useState('')
  const [kind, setKind] = useState<'income' | 'expense'>('expense')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!supabase) { setLoading(false); return }
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
      setLoading(false)
    })
    const { data: listener } = supabase.auth.onAuthStateChange((_event, next) => setSession(next))
    return () => listener.subscription.unsubscribe()
  }, [])

  useEffect(() => {
    if (!session || !supabase) { setTransactions([]); return }
    let active = true
    supabase.from('account_balances').select('account_id, name, current_balance').eq('is_active', true).then(({ data }) => {
      if (active) { const rows = (data ?? []) as Account[]; setAccounts(rows); if (!accountId && rows[0]) setAccountId(rows[0].account_id) }
    })
    supabase.from('financial_transactions')
      .select('id, description, amount, kind, occurred_at, status, category:categories(name), account:financial_accounts(name)')
      .order('occurred_at', { ascending: false }).limit(8)
      .then(({ data, error: queryError }) => {
        if (!active) return
        if (queryError) setError(queryError.message)
        else setTransactions((data ?? []) as unknown as Transaction[])
      })
    return () => { active = false }
  }, [session, accountId])

  const totals = useMemo(() => transactions.reduce((acc, item) => {
    if (item.status === 'posted') acc[item.kind] += Number(item.amount)
    return acc
  }, { income: 0, expense: 0 }), [transactions])

  async function signIn(event: FormEvent) {
    event.preventDefault()
    if (!supabase) return
    setAuthMessage('')
    const { error: authError } = await supabase.auth.signInWithPassword({ email, password })
    if (authError) setAuthMessage(authError.message)
  }

  async function signUp() {
    if (!supabase) return
    setAuthMessage('')
    const { error: authError } = await supabase.auth.signUp({ email, password })
    setAuthMessage(authError ? authError.message : 'Cadastro iniciado. Confira seu e-mail para confirmar a conta.')
  }

  async function addTransaction(event: FormEvent) {
    event.preventDefault()
    if (!supabase || !session?.user) return
    if (!accountId) { setError('Crie ou selecione uma conta antes de registrar uma movimentação.'); return }
    const parsed = Number(amount.replace(',', '.'))
    if (!description.trim() || !Number.isFinite(parsed) || parsed <= 0) {
      setError('Informe uma descrição e um valor maior que zero.')
      return
    }
    setSaving(true); setError('')
    const { error: insertError } = await supabase.from('financial_transactions').insert({
      owner_id: session.user.id,
      account_id: accountId,
      description: description.trim(),
      amount: parsed.toFixed(2),
      kind,
      occurred_at: new Date().toISOString(),
      status: 'posted',
      currency: 'BRL',
      visibility: 'private',
    })
    setSaving(false)
    if (insertError) { setError(insertError.message); return }
    setDescription(''); setAmount(''); setShowForm(false)
    const { data } = await supabase.from('financial_transactions')
      .select('id, description, amount, kind, occurred_at, status, category:categories(name), account:financial_accounts(name)')
      .order('occurred_at', { ascending: false }).limit(8)
    setTransactions((data ?? []) as unknown as Transaction[])
  }

  if (loading) return <div className="loading-screen">Carregando Finance…</div>

  if (!isSupabaseConfigured) return (
    <main className="setup-screen">
      <div className="setup-card">
        <div className="brand-mark"><Wallet size={24} /></div>
        <p className="eyebrow">CONFIGURAÇÃO INICIAL</p>
        <h1>Conecte seu projeto Supabase</h1>
        <p>Para ativar autenticação e persistência real, configure as variáveis do Supabase no arquivo <code>.env</code>. A chave pública anon é própria para o navegador; nunca use a service role no frontend.</p>
        <div className="setup-code">VITE_SUPABASE_URL=https://seu-projeto.supabase.co<br/>VITE_SUPABASE_ANON_KEY=sua-chave-anon</div>
        <p className="muted">Depois, aplique a migration em <code>supabase/migrations</code> e execute <code>npm run dev</code>.</p>
      </div>
    </main>
  )

  if (!session) return (
    <main className="auth-screen">
      <section className="auth-brand">
        <div className="brand-mark"><Wallet size={25} /></div>
        <p className="eyebrow">FINANÇAS COM CLAREZA</p>
        <h1>Seu dinheiro,<br/><span>sob seu controle.</span></h1>
        <p>Uma visão organizada da sua vida financeira, com privacidade desde a primeira movimentação.</p>
        <div className="auth-proof"><ShieldCheck size={17}/> Seus dados protegidos por autenticação e políticas de acesso.</div>
      </section>
      <form className="auth-card" onSubmit={signIn}>
        <p className="eyebrow">BEM-VINDO(A)</p><h2>Acesse sua conta</h2><p className="muted">Entre ou crie seu cadastro para começar.</p>
        <label>E-mail<input type="email" required value={email} onChange={e => setEmail(e.target.value)} placeholder="voce@email.com"/></label>
        <label>Senha<input type="password" required minLength={6} value={password} onChange={e => setPassword(e.target.value)} placeholder="Mínimo de 6 caracteres"/></label>
        {authMessage && <p className="form-message">{authMessage}</p>}
        <button className="primary-button" type="submit">Entrar</button>
        <button className="text-button" type="button" onClick={signUp}>Criar minha conta</button>
      </form>
    </main>
  )

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <div className="brand"><div className="brand-mark"><Wallet size={21}/></div><span>finance<span className="brand-dot">.</span></span></div>
        <p className="nav-caption">VISÃO GERAL</p>
        <nav><a className="nav-link active"><LayoutDashboard size={18}/>Dashboard</a><a className="nav-link"><Receipt size={18}/>Movimentações</a><a className="nav-link"><Wallet size={18}/>Contas e carteiras</a><a className="nav-link"><CreditCard size={18}/>Cartões e faturas</a><a className="nav-link"><ChartNoAxesCombined size={18}/>Relatórios</a></nav>
        <p className="nav-caption">PLANEJAMENTO</p>
        <nav><a className="nav-link"><CalendarDays size={18}/>Orçamentos</a><a className="nav-link"><Banknote size={18}/>Reservas e metas</a></nav>
        <div className="sidebar-bottom"><a className="nav-link"><Settings size={18}/>Configurações</a><div className="privacy-note"><ShieldCheck size={17}/><span>Seu espaço financeiro<br/><b>Privado e protegido</b></span></div></div>
      </aside>
      <main className="main-area">
        <header className="topbar"><div><span className="breadcrumb">Workspace pessoal</span><span className="topbar-separator">/</span><b>Dashboard</b></div><div className="top-actions"><button className="icon-button" aria-label="Notificações"><Bell size={18}/></button><div className="avatar">{session.user.email?.slice(0,1).toUpperCase()}</div><button className="icon-button" aria-label="Sair" onClick={() => supabase?.auth.signOut()}><LogOut size={18}/></button></div></header>
        <div className="content">
          <div className="page-heading"><div><p className="eyebrow">SEXTA-FEIRA FINANCEIRA</p><h1>Visão geral</h1><p className="muted">Acompanhe o que acontece com seu dinheiro.</p></div><div className="heading-actions"><button className="subtle-button" onClick={async () => { const name = window.prompt('Nome da nova conta'); if (!name?.trim() || !supabase || !session?.user) return; const { data, error: accountError } = await supabase.from('financial_accounts').insert({ owner_id: session.user.id, name: name.trim(), account_type: 'checking', opening_balance: 0 }).select('id, name').single(); if (accountError) setError(accountError.message); else if (data) { setAccounts(current => [...current, { account_id: data.id, name: data.name, current_balance: 0 }]); setAccountId(data.id) } }}>Criar conta</button><button className="primary-button add-button" onClick={() => setShowForm(true)}><Plus size={18}/>Nova movimentação</button></div></div>
          {error && <div className="error-banner">{error}</div>}
          {showForm && <form className="transaction-form" onSubmit={addTransaction}><div className="form-heading"><h3>Nova movimentação</h3><button type="button" className="text-button" onClick={() => setShowForm(false)}>Fechar</button></div><div className="form-grid"><label>Tipo<select value={kind} onChange={e => setKind(e.target.value as 'income'|'expense')}><option value="expense">Despesa</option><option value="income">Receita</option></select></label><label>Conta<select required value={accountId} onChange={e => setAccountId(e.target.value)}><option value=''>Selecione uma conta</option>{accounts.map(account => <option key={account.account_id} value={account.account_id}>{account.name}</option>)}</select></label><label>Valor (R$)<input required value={amount} onChange={e => setAmount(e.target.value)} placeholder="0,00" inputMode="decimal"/></label><label className="wide-field">Descrição<input required value={description} onChange={e => setDescription(e.target.value)} placeholder="Ex.: almoço, Uber, salário…"/></label></div>{accounts.length === 0 && <p className="muted">Nenhuma conta cadastrada. Crie uma conta para começar.</p>}<button className="primary-button" disabled={saving || !accountId}>{saving ? 'Salvando…' : 'Salvar movimentação'}</button></form>}
          <section className="metric-grid">
            <article className="metric-card balance-card"><div className="metric-top"><span>Saldo das movimentações recentes</span><span className="metric-icon"><Wallet size={18}/></span></div><strong>{money(accounts.reduce((sum, account) => sum + Number(account.current_balance), 0))}</strong><small>Saldo contábil das contas ativas</small><div className="balance-decoration"/></article>
            <article className="metric-card"><div className="metric-top"><span>Receitas recentes</span><span className="metric-icon green"><ArrowDownLeft size={18}/></span></div><strong>{money(totals.income)}</strong><small>Movimentações confirmadas</small></article>
            <article className="metric-card"><div className="metric-top"><span>Despesas recentes</span><span className="metric-icon red"><ArrowUpRight size={18}/></span></div><strong>{money(totals.expense)}</strong><small>Movimentações confirmadas</small></article>
          </section>
          <section className="section-grid"><article className="panel transactions-panel"><div className="panel-heading"><div><h2>Movimentações recentes</h2><p className="muted">Seus últimos registros financeiros</p></div><button className="subtle-button" onClick={() => setShowForm(true)}>Adicionar <Plus size={15}/></button></div>
            {transactions.length === 0 ? <div className="empty-state"><div className="empty-icon"><Receipt size={22}/></div><b>Nenhuma movimentação ainda</b><p>Registre sua primeira receita ou despesa para começar a acompanhar suas finanças.</p><button className="primary-button" onClick={() => setShowForm(true)}><Plus size={17}/>Adicionar lançamento</button></div> :
              <div className="transaction-list">{transactions.map(item => <div className="transaction-row" key={item.id}><div className={'transaction-icon '+item.kind}>{item.kind === 'income' ? <ArrowDownLeft size={18}/> : <ArrowUpRight size={18}/>}</div><div className="transaction-description"><b>{item.description}</b><span>{item.category?.name ?? (item.kind === 'income' ? 'Receita' : 'Despesa')} · {dateLabel.format(new Date(item.occurred_at))}</span></div><strong className={item.kind}>{item.kind === 'income' ? '+' : '−'} {money(Number(item.amount))}</strong></div>)}</div>}
          </article>
          <article className="panel side-panel"><div className="panel-heading"><div><h2>Seu espaço</h2><p className="muted">Privacidade em primeiro lugar</p></div><ShieldCheck size={19} className="panel-icon"/></div><div className="workspace-card"><div className="workspace-symbol"><Wallet size={20}/></div><div><b>Finanças pessoais</b><span>Espaço privado</span></div><span className="status-pill">Ativo</span></div><div className="side-tip"><CircleHelp size={18}/><p>Seus registros pessoais não são compartilhados automaticamente. Espaços compartilhados serão configurados separadamente.</p></div><div className="side-footer"><span>Moeda principal</span><b>BRL · Real brasileiro</b></div><div className="side-footer"><span>Fuso horário padrão</span><b>America/Fortaleza</b></div></article></section>
          <footer className="footer-note">Finance <span>·</span> Seus dados financeiros pertencem a você.</footer>
        </div>
      </main>
    </div>
  )
}
