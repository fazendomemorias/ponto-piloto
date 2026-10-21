-- ============================================================
-- PILOTO: Ponto interno por celular (Secretaria de Saude de Exu)
-- Dados FICTICIOS. Rode este arquivo inteiro no SQL Editor do
-- Supabase, no projeto escolhido para o piloto.
-- Tudo fica isolado com o prefixo ponto_.
-- Para desfazer: drop table ponto_marcacoes, ponto_funcionarios,
--   ponto_gestores, ponto_config; e apague as funcoes ponto_*.
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

-- Nenhum acesso direto do navegador as tabelas: so via funcoes.
alter table ponto_funcionarios enable row level security;
alter table ponto_gestores enable row level security;
alter table ponto_config enable row level security;
alter table ponto_marcacoes enable row level security;

create or replace function ponto_dist_m(lat1 float, lon1 float, lat2 float, lon2 float)
returns float language sql immutable as $$
  select 6371000 * 2 * asin(sqrt(
    power(sin(radians(lat2-lat1)/2),2) +
    cos(radians(lat1))*cos(radians(lat2))*power(sin(radians(lon2-lon1)/2),2)
  ))::float
$$;

-- Login do funcionario: devolve nome se matricula+PIN conferem
create or replace function ponto_login(p_matricula text, p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare f record; c record;
begin
  select * into f from ponto_funcionarios
   where matricula = upper(trim(p_matricula)) and pin = trim(p_pin) and ativo;
  if not found then
    return json_build_object('ok', false, 'erro', 'Matricula ou PIN invalidos.');
  end if;
  select * into c from ponto_config where id = 1;
  return json_build_object(
    'ok', true,
    'nome', f.nome,
    'matricula', f.matricula,
    'cerca_configurada', (c.id is not null and c.centro_lat is not null),
    'cerca_rotulo', coalesce(c.rotulo, 'Local de trabalho (piloto)')
  );
end $$;

-- Status do dia do funcionario (fuso America/Sao_Paulo)
create or replace function ponto_status(p_matricula text, p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare f record; v_dia date;
begin
  select * into f from ponto_funcionarios
   where matricula = upper(trim(p_matricula)) and pin = trim(p_pin) and ativo;
  if not found then
    return json_build_object('ok', false, 'erro', 'Matricula ou PIN invalidos.');
  end if;
  v_dia := (now() at time zone 'America/Sao_Paulo')::date;
  return json_build_object(
    'ok', true,
    'nome', f.nome,
    'dia', v_dia,
    'marcacoes', coalesce((
      select json_agg(json_build_object(
        'modo', m.modo,
        'hora', to_char(m.marcada_em at time zone 'America/Sao_Paulo', 'HH24:MI'),
        'distancia_m', round(m.distancia_m)
      ) order by m.marcada_em)
      from ponto_marcacoes m
      where m.funcionario_id = f.id
        and (m.marcada_em at time zone 'America/Sao_Paulo')::date = v_dia
    ), '[]'::json)
  );
end $$;

-- Registrar ponto: valida PIN, exige cerca configurada, exige estar dentro
create or replace function ponto_registrar(p_matricula text, p_pin text,
  p_lat float, p_lon float, p_accuracy float, p_device_ts timestamptz, p_ua text)
returns json language plpgsql security definer set search_path = public as $$
declare f record; c record; v_modo text; v_dist float; v_dia date;
        v_ultima timestamptz; v_agora timestamptz := now();
begin
  select * into f from ponto_funcionarios
   where matricula = upper(trim(p_matricula)) and pin = trim(p_pin) and ativo;
  if not found then
    return json_build_object('ok', false, 'erro', 'Matricula ou PIN invalidos.');
  end if;
  select * into c from ponto_config where id = 1;
  if c.id is null or c.centro_lat is null then
    return json_build_object('ok', false, 'erro',
      'Local de trabalho ainda nao configurado. Fale com o gestor.');
  end if;
  -- distancia calculada no SERVIDOR, nao no aparelho
  v_dist := ponto_dist_m(p_lat, p_lon, c.centro_lat, c.centro_lon);
  if v_dist > c.raio_m then
    return json_build_object('ok', false, 'erro', 'fora_do_local',
      'distancia_m', round(v_dist), 'raio_m', c.raio_m);
  end if;
  -- evita dupla batida por toque repetido
  select max(m.marcada_em) into v_ultima from ponto_marcacoes m
   where m.funcionario_id = f.id;
  if v_ultima is not null and v_agora - v_ultima < interval '60 seconds' then
    return json_build_object('ok', false, 'erro',
      'Ultima marcacao ha menos de 1 minuto. Aguarde e tente de novo.');
  end if;
  v_dia := (v_agora at time zone 'America/Sao_Paulo')::date;
  select case when count(*) filter (where modo = 'ENTRADA')
                 > count(*) filter (where modo = 'SAIDA')
              then 'SAIDA' else 'ENTRADA' end
    into v_modo
    from ponto_marcacoes m
   where m.funcionario_id = f.id
     and (m.marcada_em at time zone 'America/Sao_Paulo')::date = v_dia;
  insert into ponto_marcacoes
    (funcionario_id, modo, device_em, lat, lon, precisao_m, distancia_m, user_agent)
  values
    (f.id, v_modo, p_device_ts, p_lat, p_lon, p_accuracy, v_dist, left(coalesce(p_ua,''),300));
  return json_build_object(
    'ok', true, 'modo', v_modo,
    'marcada_em', v_agora,
    'distancia_m', round(v_dist),
    'precisao_m', round(coalesce(p_accuracy,0))
  );
end $$;

-- ------- Gestor -------
create or replace function ponto_admin_login(p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare g record;
begin
  select * into g from ponto_gestores where pin = trim(p_pin);
  if not found then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido.');
  end if;
  return json_build_object('ok', true, 'nome', g.nome);
end $$;

create or replace function ponto_admin_painel(p_pin text, p_data date)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from ponto_gestores where pin = trim(p_pin)) then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido.');
  end if;
  return json_build_object(
    'ok', true,
    'dia', p_data,
    'funcionarios', coalesce((
      select json_agg(json_build_object(
        'nome', f.nome,
        'matricula', f.matricula,
        'presente', (
          select (count(*) filter (where modo='ENTRADA') >
                  count(*) filter (where modo='SAIDA'))
          from ponto_marcacoes m where m.funcionario_id = f.id
            and (m.marcada_em at time zone 'America/Sao_Paulo')::date = p_data
        ),
        'marcacoes', coalesce((
          select json_agg(json_build_object(
            'modo', m.modo,
            'hora', to_char(m.marcada_em at time zone 'America/Sao_Paulo','HH24:MI'),
            'distancia_m', round(m.distancia_m),
            'precisao_m', round(coalesce(m.precisao_m,0))
          ) order by m.marcada_em)
          from ponto_marcacoes m where m.funcionario_id = f.id
            and (m.marcada_em at time zone 'America/Sao_Paulo')::date = p_data
        ), '[]'::json)
      ) order by f.nome)
      from ponto_funcionarios f where f.ativo
    ), '[]'::json)
  );
end $$;

create or replace function ponto_admin_config(p_pin text)
returns json language plpgsql security definer set search_path = public as $$
declare c record;
begin
  if not exists (select 1 from ponto_gestores where pin = trim(p_pin)) then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido.');
  end if;
  select * into c from ponto_config where id = 1;
  if c.id is null then
    return json_build_object('ok', true, 'configurada', false, 'raio_m', 100);
  end if;
  return json_build_object(
    'ok', true,
    'configurada', c.centro_lat is not null,
    'centro_lat', c.centro_lat, 'centro_lon', c.centro_lon,
    'raio_m', c.raio_m, 'rotulo', c.rotulo,
    'updated_at', c.updated_at
  );
end $$;

create or replace function ponto_admin_set_cerca(p_pin text,
  p_lat float, p_lon float, p_raio int, p_rotulo text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from ponto_gestores where pin = trim(p_pin)) then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido.');
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

create or replace function ponto_admin_add_func(p_pin text,
  p_nome text, p_matricula text, p_pin_func text)
returns json language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from ponto_gestores where pin = trim(p_pin)) then
    return json_build_object('ok', false, 'erro', 'PIN de gestor invalido.');
  end if;
  if length(trim(coalesce(p_nome,''))) < 3 then
    return json_build_object('ok', false, 'erro', 'Informe o nome.');
  end if;
  if p_pin_func is null or p_pin_func !~ '^\d{4,6}$' then
    return json_build_object('ok', false, 'erro', 'PIN do funcionario: 4 a 6 numeros.');
  end if;
  insert into ponto_funcionarios (nome, matricula, pin)
  values (trim(p_nome), upper(trim(p_matricula)), p_pin_func);
  return json_build_object('ok', true);
exception when unique_violation then
  return json_build_object('ok', false, 'erro', 'Matricula ja existe.');
end $$;

grant execute on function ponto_dist_m(float,float,float,float) to anon;
grant execute on function ponto_login(text,text) to anon;
grant execute on function ponto_status(text,text) to anon;
grant execute on function ponto_registrar(text,text,float,float,float,timestamptz,text) to anon;
grant execute on function ponto_admin_login(text) to anon;
grant execute on function ponto_admin_painel(text,date) to anon;
grant execute on function ponto_admin_config(text) to anon;
grant execute on function ponto_admin_set_cerca(text,float,float,int,text) to anon;
grant execute on function ponto_admin_add_func(text,text,text,text) to anon;

-- ------- Dados FICTICIOS do piloto -------
-- ATENCAO: NUNCA publique PINs reais aqui. Substitua os valores abaixo
-- localmente antes de rodar, guarde as credenciais em gerenciador seguro
-- (cofre) e nao commite os valores reais. Gestor: senha longa e aleatoria.
insert into ponto_gestores (nome, pin) values ('Gestor Piloto', 'SUBSTITUA-POR-SENHA-FORTE');

insert into ponto_funcionarios (nome, matricula, pin) values
  ('Ana Exemplo',    'FIC-001', 'SUBSTITUA-PIN-4A6-DIGITOS'),
  ('Bruno Teste',    'FIC-002', 'SUBSTITUA-PIN-4A6-DIGITOS'),
  ('Carla Amostra',  'FIC-003', 'SUBSTITUA-PIN-4A6-DIGITOS'),
  ('Diego Simulado', 'FIC-004', 'SUBSTITUA-PIN-4A6-DIGITOS'),
  ('Elisa Ficticia', 'FIC-005', 'SUBSTITUA-PIN-4A6-DIGITOS');
