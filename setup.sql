-- ============================================================
-- PILOTO: Ponto interno por celular (Secretaria de Saude de Exu)
-- VERSAO COMPLETA E AUTOCONTIDA (igual ao banco em producao).
-- Dados FICTICIOS. Tudo isolado com prefixo ponto_.
-- Para desfazer: drop table ponto_marcacoes, ponto_funcionarios,
--   ponto_gestores, ponto_config, ponto_tentativas;
--   e apague as funcoes ponto_*.
-- ATENCAO: NUNCA publique PINs/senhas reais neste arquivo.
-- ============================================================

create table if not exists ponto_funcionarios (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  matricula text not null unique,
  pin text not null,
  ativo boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists ponto_gestores (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  pin text not null
);

create table if not exists ponto_config (
  id int primary key default 1 check (id = 1),
  centro_lat double precision,
  centro_lon double precision,
  raio_m int not null default 100,
  rotulo text default 'Local de trabalho (piloto)',
  updated_at timestamptz not null default now()
);

create table if not exists ponto_marcacoes (
  id bigint generated always as identity primary key,
  funcionario_id uuid not null references ponto_funcionarios(id),
  modo text not null check (modo in ('ENTRADA','SAIDA')),
  marcada_em timestamptz not null default now(), -- horario do SERVIDOR
  device_em timestamptz,                          -- horario informado pelo aparelho
  lat double precision,
  lon double precision,
  precisao_m double precision,
  distancia_m double precision,
  user_agent text
);

create table if not exists ponto_tentativas (
  chave text not null,
  em timestamptz not null default now()
);

-- Nenhum acesso direto do navegador as tabelas: so via funcoes.
alter table ponto_funcionarios enable row level security;
alter table ponto_gestores enable row level security;
alter table ponto_config enable row level security;
alter table ponto_marcacoes enable row level security;
alter table ponto_tentativas enable row level security;

-- ------- Helpers INTERNOS (sem EXECUTE para ninguem de fora) -------
create or replace function ponto_dist_m(lat1 float, lon1 float, lat2 float, lon2 float)
returns float language sql immutable as $$
  select 6371000 * 2 * asin(sqrt(
    power(sin(radians(lat2-lat1)/2),2) +
    cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lon2-lon1)/2),2)
  ))::float
$$;

create or replace function ponto_bloqueado(p_chave text)
returns boolean language sql security definer set search_path = public as $$
  select (select count(*) from ponto_tentativas
          where chave = p_chave and em > now() - interval '10 minutes') >= 5
$$;

create or replace function ponto_falha(p_chave text)
returns void language sql security definer set search_path = public as $$
  insert into ponto_tentativas (chave) values (p_chave)
$$;

create or replace function ponto_limpar_falhas(p_chave text)
returns void language sql security definer set search_path = public as $$
  delete from ponto_tentativas where chave = p_chave
$$;

create or replace function ponto_gestor_ok(p_pin text)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if ponto_bloqueado('GESTOR') then return false; end if;
  if exists (select 1 from ponto_gestores where pin = trim(p_pin)) then
    perform ponto_limpar_falhas('GESTOR'); return true;
  end if;
  perform ponto_falha('GESTOR'); return false;
end $$;

-- Helpers NAO podem ser chamados de fora (senao ponto_limpar_falhas
-- contornaria o bloqueio por tentativas):
revoke all on function ponto_dist_m(float,float,float,float) from public, anon, authenticated;
revoke all on function ponto_bloqueado(text) from public, anon, authenticated;
revoke all on function ponto_falha(text) from public, anon, authenticated;
revoke all on function ponto_limpar_falhas(text) from public, anon, authenticated;
revoke all on function ponto_gestor_ok(text) from public, anon, authenticated;

-- ------- Funcionario -------
create or replace function ponto_login(p_matricula text, p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare f record; c record; k text := upper(trim(p_matricula));
begin
  if ponto_bloqueado(k) then
    return json_build_object('ok', false, 'erro', 'Muitas tentativas. Aguarde 10 minutos.');
  end if;
  select * into f from ponto_funcionarios where matricula = k and pin = trim(p_pin) and ativo;
  if not found then
    perform ponto_falha(k);
    return json_build_object('ok', false, 'erro', 'Matricula ou PIN invalidos.');
  end if;
  perform ponto_limpar_falhas(k);
  select * into c from ponto_config where id = 1;
  return json_build_object('ok', true, 'nome', f.nome, 'matricula', f.matricula,
    'cerca_configurada', (c.id is not null and c.centro_lat is not null),
    'cerca_rotulo', coalesce(c.rotulo, 'Local de trabalho (piloto)'));
end $$;

create or replace function ponto_status(p_matricula text, p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare f record; v_dia date; k text := upper(trim(p_matricula));
begin
  if ponto_bloqueado(k) then
    return json_build_object('ok', false, 'erro', 'Muitas tentativas. Aguarde 10 minutos.');
  end if;
  select * into f from ponto_funcionarios where matricula = k and pin = trim(p_pin) and ativo;
  if not found then
    perform ponto_falha(k);
    return json_build_object('ok', false, 'erro', 'Matricula ou PIN invalidos.');
  end if;
  v_dia := (now() at time zone 'America/Sao_Paulo')::date;
  return json_build_object('ok', true, 'nome', f.nome, 'dia', v_dia,
    'marcacoes', coalesce((
      select json_agg(json_build_object(
        'modo', m.modo,
        'hora', to_char(m.marcada_em at time zone 'America/Sao_Paulo', 'HH24:MI'),
        'distancia_m', round(m.distancia_m)
      ) order by m.marcada_em)
      from ponto_marcacoes m
      where m.funcionario_id = f.id
        and (m.marcada_em at time zone 'America/Sao_Paulo')::date = v_dia
    ), '[]'::json));
end $$;

create or replace function ponto_registrar(p_matricula text, p_pin text,
  p_lat float, p_lon float, p_accuracy float, p_device_ts timestamptz, p_ua text)
returns json language plpgsql security definer set search_path = public as $$
declare f record; c record; v_modo text; v_dist float; v_dia date;
        v_ultima timestamptz; v_agora timestamptz := now(); k text := upper(trim(p_matricula));
begin
  if ponto_bloqueado(k) then
    return json_build_object('ok', false, 'erro', 'Muitas tentativas. Aguarde 10 minutos.');
  end if;
  -- coordenadas obrigatorias e validas (NULL passaria pelo IF de distancia)
  if p_lat is null or p_lon is null
     or not (p_lat between -90 and 90) or not (p_lon between -180 and 180)
     or p_lat::text = 'NaN' or p_lon::text = 'NaN'
     or p_lat in ('Infinity'::float, '-Infinity'::float)
     or p_lon in ('Infinity'::float, '-Infinity'::float) then
    return json_build_object('ok', false, 'erro', 'Localizacao invalida ou ausente.');
  end if;
  select * into f from ponto_funcionarios where matricula = k and pin = trim(p_pin) and ativo;
  if not found then
    perform ponto_falha(k);
    return json_build_object('ok', false, 'erro', 'Matricula ou PIN invalidos.');
  end if;
  perform ponto_limpar_falhas(k);
  select * into c from ponto_config where id = 1;
  if c.id is null or c.centro_lat is null then
    return json_build_object('ok', false, 'erro', 'Local de trabalho ainda nao configurado. Fale com o gestor.');
  end if;
  v_dist := ponto_dist_m(p_lat, p_lon, c.centro_lat, c.centro_lon);
  if v_dist > c.raio_m then
    return json_build_object('ok', false, 'erro', 'fora_do_local',
      'distancia_m', round(v_dist), 'raio_m', c.raio_m);
  end if;
  select max(m.marcada_em) into v_ultima from ponto_marcacoes m where m.funcionario_id = f.id;
  if v_ultima is not null and v_agora - v_ultima < interval '60 seconds' then
    return json_build_object('ok', false, 'erro', 'Ultima marcacao ha menos de 1 minuto. Aguarde e tente de novo.');
  end if;
  v_dia := (v_agora at time zone 'America/Sao_Paulo')::date;
  select case when count(*) filter (where modo = 'ENTRADA') > count(*) filter (where modo = 'SAIDA')
              then 'SAIDA' else 'ENTRADA' end into v_modo
    from ponto_marcacoes m where m.funcionario_id = f.id
     and (m.marcada_em at time zone 'America/Sao_Paulo')::date = v_dia;
  insert into ponto_marcacoes (funcionario_id, modo, device_em, lat, lon, precisao_m, distancia_m, user_agent)
  values (f.id, v_modo, p_device_ts, p_lat, p_lon, p_accuracy, v_dist, left(coalesce(p_ua,''),300));
  return json_build_object('ok', true, 'modo', v_modo, 'marcada_em', v_agora,
    'distancia_m', round(v_dist), 'precisao_m', round(coalesce(p_accuracy,0)));
end $$;

-- ------- Gestor -------
create or replace function ponto_admin_login(p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare g record;
begin
  if ponto_bloqueado('GESTOR') then
    return json_build_object('ok', false, 'erro', 'Muitas tentativas. Aguarde 10 minutos.');
  end if;
  select * into g from ponto_gestores where pin = trim(p_pin);
  if not found then
    perform ponto_falha('GESTOR');
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido.');
  end if;
  perform ponto_limpar_falhas('GESTOR');
  return json_build_object('ok', true, 'nome', g.nome);
end $$;

create or replace function ponto_admin_painel(p_pin text, p_data date)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not ponto_gestor_ok(p_pin) then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido ou bloqueado temporariamente.');
  end if;
  return json_build_object('ok', true, 'dia', p_data,
    'funcionarios', coalesce((
      select json_agg(json_build_object(
        'nome', f.nome, 'matricula', f.matricula,
        'presente', (select (count(*) filter (where modo='ENTRADA') > count(*) filter (where modo='SAIDA'))
                     from ponto_marcacoes m where m.funcionario_id = f.id
                       and (m.marcada_em at time zone 'America/Sao_Paulo')::date = p_data),
        'marcacoes', coalesce((
          select json_agg(json_build_object('modo', m.modo,
            'hora', to_char(m.marcada_em at time zone 'America/Sao_Paulo','HH24:MI'),
            'distancia_m', round(m.distancia_m), 'precisao_m', round(coalesce(m.precisao_m,0)))
          order by m.marcada_em)
          from ponto_marcacoes m where m.funcionario_id = f.id
            and (m.marcada_em at time zone 'America/Sao_Paulo')::date = p_data
        ), '[]'::json)
      ) order by f.nome)
      from ponto_funcionarios f where f.ativo
    ), '[]'::json));
end $$;

create or replace function ponto_admin_config(p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare c record;
begin
  if not ponto_gestor_ok(p_pin) then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido ou bloqueado temporariamente.');
  end if;
  select * into c from ponto_config where id = 1;
  if c.id is null then
    return json_build_object('ok', true, 'configurada', false, 'raio_m', 100);
  end if;
  return json_build_object('ok', true, 'configurada', c.centro_lat is not null,
    'centro_lat', c.centro_lat, 'centro_lon', c.centro_lon,
    'raio_m', c.raio_m, 'rotulo', c.rotulo, 'updated_at', c.updated_at);
end $$;

create or replace function ponto_admin_set_cerca(p_pin text, p_lat float, p_lon float, p_raio int, p_rotulo text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not ponto_gestor_ok(p_pin) then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido ou bloqueado temporariamente.');
  end if;
  if p_lat is null or p_lon is null
     or not (p_lat between -90 and 90) or not (p_lon between -180 and 180)
     or p_lat in ('Infinity'::float, '-Infinity'::float)
     or p_lon in ('Infinity'::float, '-Infinity'::float) then
    return json_build_object('ok', false, 'erro', 'Coordenadas do local invalidas.');
  end if;
  if p_raio is null or p_raio < 30 or p_raio > 2000 then
    return json_build_object('ok', false, 'erro', 'Raio deve ficar entre 30 e 2000 metros.');
  end if;
  insert into ponto_config (id, centro_lat, centro_lon, raio_m, rotulo, updated_at)
  values (1, p_lat, p_lon, p_raio, left(coalesce(nullif(trim(p_rotulo),''),'Local de trabalho (piloto)'),120), now())
  on conflict (id) do update
    set centro_lat = excluded.centro_lat, centro_lon = excluded.centro_lon,
        raio_m = excluded.raio_m, rotulo = excluded.rotulo, updated_at = now();
  return json_build_object('ok', true);
end $$;

create or replace function ponto_admin_add_func(p_pin text, p_nome text, p_matricula text, p_pin_func text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not ponto_gestor_ok(p_pin) then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido ou bloqueado temporariamente.');
  end if;
  if length(trim(coalesce(p_nome,''))) < 3 then
    return json_build_object('ok', false, 'erro', 'Informe o nome.');
  end if;
  if p_pin_func is null or p_pin_func !~ '^\d{4,6}$' then
    return json_build_object('ok', false, 'erro', 'PIN do funcionario: 4 a 6 numeros.');
  end if;
  insert into ponto_funcionarios (nome, matricula, pin) values (trim(p_nome), upper(trim(p_matricula)), p_pin_func);
  return json_build_object('ok', true);
exception when unique_violation then
  return json_build_object('ok', false, 'erro', 'Matricula ja existe.');
end $$;

-- Gestor troca a propria senha (minimo 12 caracteres)
create or replace function ponto_admin_trocar_senha(p_pin_atual text, p_senha_nova text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not ponto_gestor_ok(p_pin_atual) then
    return json_build_object('ok', false, 'erro', 'Senha atual invalida ou bloqueada temporariamente.');
  end if;
  if p_senha_nova is null or length(p_senha_nova) < 12 then
    return json_build_object('ok', false, 'erro', 'A nova senha precisa de pelo menos 12 caracteres.');
  end if;
  update ponto_gestores set pin = p_senha_nova;
  return json_build_object('ok', true);
end $$;

-- Gestor redefine o PIN de um funcionario
create or replace function ponto_admin_set_pin_func(p_pin text, p_matricula text, p_pin_novo text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not ponto_gestor_ok(p_pin) then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido ou bloqueado temporariamente.');
  end if;
  if p_pin_novo is null or p_pin_novo !~ '^\d{4,6}$' then
    return json_build_object('ok', false, 'erro', 'PIN do funcionario: 4 a 6 numeros.');
  end if;
  update ponto_funcionarios set pin = p_pin_novo where matricula = upper(trim(p_matricula));
  if not found then
    return json_build_object('ok', false, 'erro', 'Matricula nao encontrada.');
  end if;
  return json_build_object('ok', true);
end $$;

-- Pontos de entrada: tiro o EXECUTE padrao (PUBLIC) e libero so para anon
-- (o piloto nao usa usuarios autenticados; usuarios da escola NAO podem
-- chamar nada do ponto).
revoke all on function ponto_login(text,text) from public, anon, authenticated;
revoke all on function ponto_status(text,text) from public, anon, authenticated;
revoke all on function ponto_registrar(text,text,float,float,float,timestamptz,text) from public, anon, authenticated;
revoke all on function ponto_admin_login(text) from public, anon, authenticated;
revoke all on function ponto_admin_painel(text,date) from public, anon, authenticated;
revoke all on function ponto_admin_config(text) from public, anon, authenticated;
revoke all on function ponto_admin_set_cerca(text,float,float,int,text) from public, anon, authenticated;
revoke all on function ponto_admin_add_func(text,text,text,text) from public, anon, authenticated;
revoke all on function ponto_admin_trocar_senha(text,text) from public, anon, authenticated;
revoke all on function ponto_admin_set_pin_func(text,text,text) from public, anon, authenticated;

grant execute on function ponto_login(text,text) to anon;
grant execute on function ponto_status(text,text) to anon;
grant execute on function ponto_registrar(text,text,float,float,float,timestamptz,text) to anon;
grant execute on function ponto_admin_login(text) to anon;
grant execute on function ponto_admin_painel(text,date) to anon;
grant execute on function ponto_admin_config(text) to anon;
grant execute on function ponto_admin_set_cerca(text,float,float,int,text) to anon;
grant execute on function ponto_admin_add_func(text,text,text,text) to anon;
grant execute on function ponto_admin_trocar_senha(text,text) to anon;
grant execute on function ponto_admin_set_pin_func(text,text,text) to anon;

-- ------- Dados FICTICIOS do piloto (SUBSTITUA localmente; nao commite) -------
insert into ponto_gestores (nome, pin)
values ('Gestor Piloto', 'SUBSTITUA-POR-SENHA-FORTE-MIN-12')
on conflict do nothing;

insert into ponto_funcionarios (nome, matricula, pin) values
  ('Ana Exemplo',    'FIC-001', 'SUBSTITUA-PIN-4A6-DIGITOS'),
  ('Bruno Teste',    'FIC-002', 'SUBSTITUA-PIN-4A6-DIGITOS'),
  ('Carla Amostra',  'FIC-003', 'SUBSTITUA-PIN-4A6-DIGITOS'),
  ('Diego Simulado', 'FIC-004', 'SUBSTITUA-PIN-4A6-DIGITOS'),
  ('Elisa Ficticia', 'FIC-005', 'SUBSTITUA-PIN-4A6-DIGITOS')
on conflict (matricula) do nothing;
 
