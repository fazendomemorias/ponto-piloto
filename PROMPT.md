# Piloto: Ponto interno por celular - Secretaria de Saude de Exu

Guia do pacote + prompt autossuficiente para recriar o sistema.
Sistema de controle INTERNO de presenca pelo celular, com geolocalizacao.
NAO substitui o ponto oficial (Kairos/Control iD), que segue intocado.
Dados 100% ficticios durante o piloto.

## O que foi entregue (implementado e testado)

- Pagina do funcionario (`index.html`): login por matricula + senha, botao
  "BATER PONTO" que so funciona DENTRO da cerca virtual configurada,
  alternancia automatica ENTRADA/SAIDA, horario gravado pelo SERVIDOR
  (nao pelo aparelho), lista das marcacoes do dia.
- Pagina do gestor (`admin.html`): painel com presentes/entradas/saidas do
  dia, configuracao da cerca virtual (centro = GPS do gestor no local +
  raio em metros), cadastro de funcionario ficticio, troca da propria
  senha de gestor e redefinicao de senha de funcionario.
- Banco (`setup.sql`): tabelas isoladas `ponto_*` dentro de um projeto
  Supabase existente, funcoes RPC como unica porta de entrada. Sem acesso
  direto as tabelas pelo navegador.

## Seguranca implementada

- RLS ativado em todas as tabelas ponto_*, sem policies: nenhuma leitura
  ou escrita direta; tudo passa pelas funcoes RPC.
- Funcoes internas (throttle e distancia) SEM permissao de execucao
  externa: chamada direta retorna "permission denied" (testado).
- As RPCs de entrada so aceitam o papel `anon`; tokens autenticados
  do sistema escolar sao recusados (revogado e auditado via
  information_schema.routine_privileges). Isso NAO impede uma pessoa
  de usar a chave publica anon diretamente: a protecao real dos dados
  do ponto e que toda RPC exige a credencial propria (senha do gestor
  ou PIN do funcionario), validada dentro da funcao, com RLS barrando
  qualquer leitura ou escrita direta nas tabelas.
- Bloqueio por tentativas: 5 erros em 10 minutos por matricula/gestor.
- Validacao no servidor: coordenadas obrigatorias, finitas e dentro da
  faixa (lat -90..90, lon -180..180) tanto no registro quanto na cerca.
- Painel do gestor protegido por senha propria. EXCECAO DO PILOTO
  FICTICIO: a senha do gestor pode ter 4 a 64 caracteres para permitir
  teste com senha simples; EM USO REAL deve ser forte (12+). Senhas de
  funcionario de 4 a 64 caracteres. Nenhum valor de senha/PIN
  consta em codigo, mensagens ou na VERSAO ATUAL do repositorio
  (o historico antigo do git contem PINs ja invalidados que nao abrem
  mais nada; a rotacao foi feita exatamente por isso).
- Anti-dupla-marcacao: minimo de 60 segundos entre marcacoes.
- Mensagens de falha de rede sao honestas: se a conexao caiu depois do
  envio, o app diz que NAO CONSEGUIU CONFIRMAR e manda conferir o
  historico antes de repetir (em vez de afirmar que nada foi gravado).
- HTML: valores digitados por usuarios sao escapados (sem injecao via
  nome/rotulo) e mensagens nao usam tags HTML.

## Limitacoes honestas

- GPS de celular pode ser falsificado com apps de "fake GPS". O piloto
  nao detecta isso; serve para controle interno com confianca, nao para
  prova juridica.
- A precisao do GPS do celular varia bastante conforme o ambiente
  (ceu aberto, predios, modelo do aparelho); por isso o raio minimo
  e 30m e marcacoes com precisao ruim sao sinalizadas.
- Nao ha relatorios/exportacao (espelho de ponto) no piloto.
- A cerca real so sera definida com o gestor NO local de trabalho;
  enquanto isso ninguem registra (comportamento verificado).
- Integracao com o relogio Control iD so sera avaliada quando o modelo
  do aparelho for identificado (foto da etiqueta pendente).
- Uso com dados reais exige aprovacao expressa do gestor.

## Como subir do zero (pacote executavel)

1. No final do `setup.sql`, ANTES de rodar, substitua os placeholders
   `SUBSTITUA-POR-SENHA-FORTE-MIN-12` e `SUBSTITUA-SENHA-4A64`
   localmente (nunca commite valores).
2. Crie um projeto Supabase gratuito e rode o `setup.sql` completo no
   SQL Editor. Ele cria tabelas, RLS, funcoes, revogacoes e grants.
3. Publique `index.html` e `admin.html` em qualquer hosting estatico
   (GitHub Pages, etc.) ajustando SUPABASE_URL/SUPABASE_KEY (a chave
   publishable e publica por desenho - a seguranca esta nas RPCs).
4. O gestor abre `admin.html` no local de trabalho e define a cerca.
5. Funcionarios abrem `index.html`, fazem login e registram.

## Prompt autossuficiente para recriar o sistema

Cole o texto abaixo em uma IA de codigo junto com o setup.sql se quiser
reproduzir o piloto em outro contexto:

---
Crie um sistema web estatico de controle de ponto interno para uso em
celular, usando Supabase (Postgres + PostgREST) como backend, sem
servidor proprio. Requisitos:

1. BANCO: tabelas com prefixo ponto_ (funcionarios, gestores, config,
   marcacoes, tentativas). RLS ativado em todas, SEM nenhuma policy, de
   modo que nenhum acesso direto as tabelas seja possivel pela API.
   Todo o acesso acontece por funcoes RPC security definer.

2. ACESSO POR PAPEIS: revogue EXECUTE de PUBLIC/anon/authenticated em
   TODAS as funcoes internas auxiliares (elas so sao chamadas de dentro
   das RPCs). Nas RPCs de entrada, revogue o EXECUTE padrao de PUBLIC e
   conceda apenas ao papel anon - usuarios autenticados de outro sistema
   no mesmo projeto nao podem chamar nada.

3. FUNCIONARIO: login por matricula + senha; botao "bater ponto" que pede
   a geolocalizacao do navegador e so grava se a distancia (haversine
   calculada no servidor) for menor que o raio configurado. ENTRADA/SAIDA
   alternam automaticamente conforme o dia. O horario gravado e o do
   servidor (now()), guardando tambem o horario do aparelho para
   auditoria. Minimo de 60 segundos entre marcacoes.

4. VALIDACAO SERVER-SIDE: rejeite lat/lon NULL, NaN, infinito ou fora de
   faixa (lat -90..90, lon -180..180) tanto no registro quanto na
   definicao da cerca. Um NULL passaria por um IF de distancia.

5. GESTOR: painel com senha propria (no piloto ficticio, 4-64
   caracteres; em uso real, forte com 12+) mostrando
   presentes/entradas/saidas por dia, definicao da cerca (centro = GPS
   atual do gestor, raio 30-2000m, rotulo), cadastro de funcionario,
   troca da propria senha e redefinicao de senha de funcionario. Updates
   sempre com WHERE (o Supabase bloqueia update de tabela inteira).

6. ANTI-FORCA-BRUTA: tabela de tentativas; 5 erros em 10 minutos por
   matricula ou para o gestor bloqueiam temporariamente. O contador zera
   no acerto, e a funcao que zera NAO pode ser chamavel de fora.

7. FRONT-END ESTATICO: dois arquivos HTML (funcionario e gestor) com a
   chave publishable do Supabase embutida (publica por desenho; a
   seguranca esta nas RPCs). Renderize qualquer texto vindo de usuario
   com textContent ou escape; mensagens de falha de rede devem dizer
   "nao foi possivel confirmar, confira o historico/a configuracao" em
   vez de afirmar que nada foi gravado, pois a conexao pode cair apos o
   commit (navigator.onLine nao prova que o envio nao saiu).

8. CONVIVENDO COM OUTRO SISTEMA no mesmo projeto Supabase: prefixo
   ponto_ + RLS sem policies fazem das RPCs a unica porta de acesso.
   Restringir grants ao papel anon impede que tokens autenticados do
   outro sistema chamem as funcoes - mas a chave anon e publica por
   desenho, entao a protecao real vem das credenciais proprias
   (senha do gestor ou senha de funcionario) exigidas dentro de cada
   RPC, mais o bloqueio por
   tentativas. Verifique com chamadas anonimas e com a auditoria de
   information_schema.routine_privileges.

9. DADOS FICTICIOS: crie funcionarios FIC-001... e um gestor com senha
   forte definida fora do codigo e fora de mensagens (use um cofre de
   senhas). Nunca versionar valores reais.
---
