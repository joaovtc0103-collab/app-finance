# Finance

Plataforma de gestão financeira pessoal e compartilhada, em português brasileiro.

## Stack
- React + TypeScript + Vite
- Tailwind CSS
- Supabase Auth + PostgreSQL + RLS
- Recharts, React Hook Form, Zod e TanStack Query

## Estado do projeto
O projeto está sendo construído por etapas. A primeira entrega estabelece a fundação técnica: autenticação, espaços financeiros isolados, contas, categorias, movimentações e trilha contábil.

## Requisitos
- Node.js 20+
- Projeto Supabase
- npm

## Desenvolvimento
```bash
npm install
cp .env.example .env
npm run dev
```

Configure `VITE_SUPABASE_URL` e `VITE_SUPABASE_ANON_KEY` no arquivo `.env`. A chave service role nunca deve ser colocada no frontend.

## Banco de dados
Aplique as migrations em `supabase/migrations` na ordem indicada, usando Supabase CLI ou SQL Editor.

## Princípios financeiros
- Valores monetários usam NUMERIC no PostgreSQL.
- Transferências não são receitas nem despesas.
- Limite de crédito não integra saldo disponível.
- Reservas são destinações de saldo, não novos ativos.
- Toda leitura/escrita de dados do usuário é protegida por RLS.
