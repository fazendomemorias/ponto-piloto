# Piloto: Ponto interno por celular - Secretaria de Saude de Exu

Sistema de controle INTERNO de presenca pelo celular, com geolocalizacao.
NAO substitui o ponto oficial (Kairos/Control iD), que segue intocado.
Dados 100% ficticios durante o piloto.

## O que foi entregue (implementado e testado)

- Pagina do funcionario (`index.html`): login por matricula + PIN, botao
  "Registrar ponto" que so funciona DENTRO da cerca virtual configurada,
  alternancia automatica ENTRADA/SAIDA, horario gravado pelo SERVIDOR
  (nao pelo aparelho), lista das marcacoes do dia.
- Pagina do gestor (`admin.html`): painel com presentes/entradas/saidas do
  dia, configuracao da cerca virtual (centro = GPS do gestor no local +
  raio em metros), cadastro de funcionario ficticio, troca da propria
  senha de gestor e redefinicao de PIN de funcionario.
- Banco (`setup.sql`): tabelas isoladas `ponto_*` dentro do projeto
  Supabase existente (mesmo banco do SigaEscola), funcoes RPC como unica
  porta de entrada. Sem acesso direto as tabelas pelo navegador.

## Seguranca implementada

- RLS ativado em todas as tabelas ponto_*, sem policies: nenhuma leitura
  ou escrita direta; tudo passa pelas funcoes RPC.
- Funcoes internas (throttle) SEM permissao de execucao externa: chamada
  direta retorna "permission denied" (testado).
- Somente o papel `anon` executa as RPCs de entrada; usuarios
  autenticados do SigaEscola NAO executam nada do ponto (revogado e
  testado).
- Bloqueio por tentativas: 5 erros em 10 minutos por matricula/gestor.
- Validacao no servidor: coordenadas obrigatorias, finitas e dentro da
  faixa (lat -90..90, lon -180..180) tanto no registro quanto na cerca.
- Painel do gestor protegido por senha forte (minimo 12 caracteres);
  PINs de funcionario de 4 a 6 digitos, definidos fora do chat via
  cofre. Nenhum valor de senha/PIN consta em codigo, repositorio ou
  mensagens.
- Anti-dupla-marcacao: minimo de 60 segundos entre marcacoes.
- HTML: valores digitados por usuarios sao escapados (sem injecao via
  nome/rotulo).

## O que ainda falta (nao implementado)

- Configuracao da cerca real: o gestor precisa estar NA Secretaria para
  definir o centro. Enquanto nao configurar, ninguem registra.
- Integracao com o relogio Control iD: aguardando foto da etiqueta do
  aparelho para avaliar modelo e API.
- Relatorios/exportacao (espelho de ponto) - nao incluido no piloto.
- Uso com dados reais exige aprovacao expressa do gestor.

## Como subir do zero (pacote executavel)

1. Crie um projeto Supabase gratuito e rode o `setup.sql` completo no
   SQL Editor. Ele cria tabelas, RLS, funcoes e revogacoes.
2. No final do `setup.sql`, substitua os placeholders
   `SUBSTITUA-POR-SENHA-FORTE-MIN-12` e `SUBSTITUA-PIN-4A6-DIGITOS`
   localmente (nunca commite valores).
3. Publique `index.html` e `admin.html` em qualquer hosting estatico
   (GitHub Pages, etc.) ajustando SUPABASE_URL/SUPABASE_KEY (a chave
   publishable e publica por desenho - a seguranca esta nas RPCs).
4. O gestor abre `admin.html` no local de trabalho e define a cerca.
5. Funcionarios abrem `index.html`, fazem login e registram.
