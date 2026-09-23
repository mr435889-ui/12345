--=========================================================================
-- Скрипт: интервалы между звонками + redial-отчёты
-- Верх воронки нарезан на отдельные temp (можно гонять по шагам и замерять время)
--=========================================================================


--=========================================================================
-- 1.1) задачи
--=========================================================================
drop table if exists tmp_tasks;
create temp table tmp_tasks as
select
    lt.id as task_id,
    lt.campaign,
    lt.payload_type,
    lt.status,
    lt.created_at
from voipclient.leasing_task lt
where lt.status in (122, 233);

create unique index on tmp_tasks (task_id);
create index on tmp_tasks (campaign);
analyze tmp_tasks;


--=========================================================================
-- 1.2) интеракции задач
--=========================================================================
drop table if exists tmp_interactions;
create temp table tmp_interactions as
select distinct
    t.task_id,
    li.id as interaction_id,
    li.contact,
    li.started as interaction_started,
    li.ended   as interaction_ended
from tmp_tasks t
join voipclient.leasing_interaction li
  on li.task = t.task_id
where (li."operator" is null or li."operator" <> 1)
  and li.ended is not null
  and li.started between timestamp '2026-09-14' and timestamp '2027-01-01'
  and li.started::time >= time '03:00:00'
  and li.started::time <  time '18:00:00';

create unique index on tmp_interactions (interaction_id);
create index on tmp_interactions (task_id, contact);
create index on tmp_interactions (contact);
analyze tmp_interactions;


--=========================================================================
-- 1.3) звонки по payload.taskId (основной путь)
--=========================================================================
drop table if exists tmp_calls_by_task;
create temp table tmp_calls_by_task as
select
    t.task_id,
    hc.id as call_id,
    hc.contact,
    hc.phone_number,
    hc.started as call_started,
    hc.ended   as call_ended,
    hc.initiator,
    'task'::text as call_source,
    1 as source_priority
from tmp_tasks t
join voipclient.history_call hc
  on (hc.payload->>'taskId')::bigint = t.task_id
where hc.ended is not null
  and hc.started between timestamp '2026-09-14' and timestamp '2027-01-01'
  and hc.started::time >= time '03:00:00'
  and hc.started::time <  time '18:00:00';

create index on tmp_calls_by_task (call_id);
create index on tmp_calls_by_task (task_id);
analyze tmp_calls_by_task;


--=========================================================================
-- 1.4) звонки по contact + окно интеракции (добор)
--=========================================================================
drop table if exists tmp_calls_by_interaction;
create temp table tmp_calls_by_interaction as
select
    i.task_id,
    hc.id as call_id,
    hc.contact,
    hc.phone_number,
    hc.started as call_started,
    hc.ended   as call_ended,
    hc.initiator,
    'interaction'::text as call_source,
    2 as source_priority
from tmp_interactions i
join voipclient.history_call hc
  on hc.contact = i.contact
where hc.ended is not null
  and hc.contact is not null
  and hc.started between timestamp '2026-09-14' and timestamp '2027-01-01'
  and hc.started::time >= time '03:00:00'
  and hc.started::time <  time '18:00:00'
  and hc.started <  i.interaction_ended
  and hc.ended   >  i.interaction_started
  and (
        hc.payload->>'taskId' is null
     or (hc.payload->>'taskId')::bigint = i.task_id
  );

create index on tmp_calls_by_interaction (call_id);
create index on tmp_calls_by_interaction (task_id);
analyze tmp_calls_by_interaction;


--=========================================================================
-- 1.5) dedup: один call_id, приоритет task > interaction
--=========================================================================
drop table if exists tmp_all_calls_dedup;
create temp table tmp_all_calls_dedup as
select distinct on (u.call_id)
    u.task_id,
    u.call_id,
    u.contact,
    u.phone_number,
    u.call_started,
    u.call_ended,
    u.initiator,
    u.call_source,
    t.campaign,
    t.payload_type,
    t.created_at as task_created_at
from (
    select * from tmp_calls_by_task
    union all
    select * from tmp_calls_by_interaction
) u
join tmp_tasks t
  on t.task_id = u.task_id
order by u.call_id, u.source_priority, u.call_started;

create unique index on tmp_all_calls_dedup (call_id);
create index on tmp_all_calls_dedup (task_id, contact);
analyze tmp_all_calls_dedup;


--=========================================================================
-- 1.6) all_calls: к звонку клеим interaction_id
--=========================================================================
drop table if exists all_calls;
create temp table all_calls as
select distinct on (ac.call_id)
    ac.task_id,
    ac.call_id,
    ac.contact,
    ac.phone_number,
    ac.call_started,
    ac.call_ended,
    ac.initiator,
    ac.call_source,
    ac.campaign,
    ac.payload_type,
    ac.task_created_at,
    i.interaction_id,
    i.interaction_started,
    i.interaction_ended
from tmp_all_calls_dedup ac
left join tmp_interactions i
  on i.task_id = ac.task_id
 and i.contact = ac.contact
 and ac.call_started <  i.interaction_ended
 and ac.call_ended   >  i.interaction_started
order by
    ac.call_id,
    i.interaction_started nulls last;

create unique index on all_calls (call_id);
create index on all_calls (task_id, phone_number, call_started);
create index on all_calls (interaction_id, call_id);
create index on all_calls (contact);
analyze all_calls;


--=========================================================================
-- 2) callresults — interaction + call
--=========================================================================
drop table if exists callresults;
create temp table callresults as
select
    ac.task_id as "Task_Id",
    ac.call_id as "call_id",
    ac.interaction_id,
    cs.title as "Результат звонка",
    cc.description as "Причина завершения звонка"
from all_calls ac
left join voipclient.leasing_call_result lcr
  on lcr.interaction = ac.interaction_id
 and lcr.call_id = ac.call_id
left join voipclient.configuration_status cs
  on cs.id = lcr.status
left join voipclient.configuration_class cc
  on cc.id = cs.class;

create unique index on callresults ("call_id");
analyze callresults;


--=========================================================================
-- 3) callnumbers + флаг «интервал в рамках дня»
--=========================================================================
drop table if exists callnumbers;
create temp table callnumbers as
with numbered_calls as (
    select
        ac.task_id as "Task_Id",
        ac.call_id as "call_id",
        ac.interaction_id,
        ac.call_started as "Дата начала звонка",
        ac.call_ended   as "Дата окончания звонка",
        ac.phone_number as "Номер телефона",
        case
            when ac.initiator = 'autocalls' then 'Системный'
            when ac.initiator is null or ac.initiator = 'inbound' then 'Ручной'
            else 'Другое'
        end as "Тип звонка",
        ac.campaign,
        ac.payload_type,
        ac.task_created_at as "Дата создания задачи",
        ac.call_source,
        row_number() over (
            partition by ac.task_id, ac.phone_number
            order by ac.call_started, ac.call_id
        ) as "Номер звонка внутри задачи",
        lag(ac.call_ended) over (
            partition by ac.task_id, ac.phone_number
            order by ac.call_started, ac.call_id
        ) as prev_call_ended
    from all_calls ac
)
select
    "Task_Id",
    "call_id",
    interaction_id,
    "Дата начала звонка",
    "Дата окончания звонка",
    "Номер телефона",
    "Тип звонка",
    campaign,
    payload_type,
    "Дата создания задачи",
    call_source,
    "Номер звонка внутри задачи",
    case
        when "Номер звонка внутри задачи" > 1 then
            round(
                extract(epoch from ("Дата начала звонка" - prev_call_ended)) / 3600::numeric
            , 3)
        else null
    end as "Интервал (в часах)",
    case
        when "Номер звонка внутри задачи" > 1 then
            case
                when extract(epoch from ("Дата начала звонка" - prev_call_ended)) < 60 then
                    round(extract(epoch from ("Дата начала звонка" - prev_call_ended))::numeric, 0) || ' сек'
                when extract(epoch from ("Дата начала звонка" - prev_call_ended)) < 3600 then
                    round(extract(epoch from ("Дата начала звонка" - prev_call_ended)) / 60::numeric, 1) || ' мин'
                when extract(epoch from ("Дата начала звонка" - prev_call_ended)) < 86400 then
                    round(extract(epoch from ("Дата начала звонка" - prev_call_ended)) / 3600::numeric, 1) || ' час'
                else
                    round(extract(epoch from ("Дата начала звонка" - prev_call_ended)) / 86400::numeric, 1) || ' дн'
            end
        else 'Первый звонок'
    end as "Интервал между звонками",
    case
        when "Номер звонка внутри задачи" > 1
         and ("Дата начала звонка")::date = prev_call_ended::date
        then 1
        else 0
    end as "Интервал в рамках дня"
from numbered_calls
order by "Task_Id", "Номер телефона", "Номер звонка внутри задачи";

create unique index on callnumbers ("call_id");
create index on callnumbers ("Task_Id", "Номер телефона", "Номер звонка внутри задачи");
create index on callnumbers ("Интервал в рамках дня");
analyze callnumbers;


--=========================================================================
-- 4) tt_final — поля как у аналитиков
--=========================================================================
drop table if exists tt_final;
create temp table tt_final as
select distinct
    cn."Task_Id",
    cn."call_id",
    cn."Дата начала звонка",
    cn."Дата окончания звонка",
    cn."Номер телефона",
    cn."Тип звонка",
    cn.campaign as "CampaignId",
    lc.name as "Название МК",
    cn."Номер звонка внутри задачи",
    case
        when lc.type = 1 then 'Исходящий'
        when lc.type = 3 and coalesce(cn.payload_type, '') != 'partners' then 'Входящий'
    end as "Канал",
    cr."Результат звонка",
    cr."Причина завершения звонка",
    cn."Интервал между звонками",
    cn."Интервал (в часах)",
    case
        when extract(hour from cn."Дата начала звонка") between 6 and 11 then 'Утро'
        when extract(hour from cn."Дата начала звонка") between 12 and 17 then 'День'
        when extract(hour from cn."Дата начала звонка") between 18 and 21 then 'Вечер'
        else 'Ночь'
    end as "Время суток звонка"
from callnumbers cn
left join voipclient.leasing_campaign lc
  on cn.campaign = lc.id
left join callresults cr
  on cr."call_id" = cn."call_id"
where cn."Интервал в рамках дня" = 1
  and cn."Интервал (в часах)" > 0
order by
    cn."Task_Id",
    cn."Номер звонка внутри задачи";

create index on tt_final ("call_id");
create index on tt_final ("CampaignId", "Канал", "Номер звонка внутри задачи");
analyze tt_final;


--=========================================================================
-- ДЕЛЕНИЕ ИНТЕРВАЛОВ НА КВАРТИЛИ ДЛЯ КАЖДОЙ МК
--=========================================================================
drop table if exists tt_intervals_with_quartiles;
create temp table tt_intervals_with_quartiles as
with quartile_boundaries as (
    select
        tf."CampaignId",
        tf."Название МК",
        tf."Канал",
        percentile_cont(0.25) within group (order by tf."Интервал (в часах)") as q1,
        percentile_cont(0.5)  within group (order by tf."Интервал (в часах)") as q2,
        percentile_cont(0.75) within group (order by tf."Интервал (в часах)") as q3
    from tt_final tf
    where tf."Интервал (в часах)" is not null
    group by tf."CampaignId", tf."Название МК", tf."Канал"
)
select
    tf."Task_Id",
    tf."call_id",
    tf."CampaignId",
    tf."Название МК",
    tf."Канал",
    tf."Номер звонка внутри задачи" as номер_попытки,
    tf."Интервал (в часах)" as интервал_часы,
    tf."Причина завершения звонка",
    case
        when tf."Причина завершения звонка" != 'Лизинг. Не удалось дозвониться' then 1
        else 0
    end as успешное_соединение,
    qb.q1, qb.q2, qb.q3,
    case
        when tf."Интервал (в часах)" <= qb.q1 then 'Группа 1 (0-25%)'
        when tf."Интервал (в часах)" <= qb.q2 then 'Группа 2 (25-50%)'
        when tf."Интервал (в часах)" <= qb.q3 then 'Группа 3 (50-75%)'
        else 'Группа 4 (75-100%)'
    end as группа_интервала_4
from tt_final tf
left join quartile_boundaries qb
  on tf."CampaignId" = qb."CampaignId"
 and tf."Название МК" is not distinct from qb."Название МК"
 and tf."Канал" is not distinct from qb."Канал"
where tf."Интервал (в часах)" is not null;

create index on tt_intervals_with_quartiles ("Task_Id", "call_id");
analyze tt_intervals_with_quartiles;


--=========================================================================
-- ДЕЛЕНИЕ ПО НОМЕРУ ЗВОНКА
--=========================================================================
drop table if exists tt_by_attempt_and_interval;
create temp table tt_by_attempt_and_interval as
with attempt_quartile_boundaries as (
    select
        tf."CampaignId",
        tf."Название МК",
        tf."Канал",
        tf."Номер звонка внутри задачи" as номер_попытки,
        percentile_cont(0.25) within group (order by tf."Интервал (в часах)") as q1_attempt,
        percentile_cont(0.5)  within group (order by tf."Интервал (в часах)") as q2_attempt,
        percentile_cont(0.75) within group (order by tf."Интервал (в часах)") as q3_attempt,
        count(*) as всего_интервалов_в_группе
    from tt_final tf
    where tf."Интервал (в часах)" is not null
      and tf."Номер звонка внутри задачи" > 1
    group by
        tf."CampaignId", tf."Название МК", tf."Канал", tf."Номер звонка внутри задачи"
    having count(*) >= 30
)
select
    tf."Task_Id",
    tf."call_id",
    tf."CampaignId",
    tf."Название МК",
    tf."Канал",
    tf."Номер звонка внутри задачи" as номер_попытки,
    tf."Интервал (в часах)" as интервал_часы,
    tf."Причина завершения звонка",
    case
        when tf."Причина завершения звонка" != 'Лизинг. Не удалось дозвониться' then 1
        else 0
    end as успешное_соединение,
    concat('Попытка ', tf."Номер звонка внутри задачи") as попытка_текст,
    ab.q1_attempt, ab.q2_attempt, ab.q3_attempt,
    ab.всего_интервалов_в_группе,
    case
        when ab.q1_attempt is not null and tf."Интервал (в часах)" <= ab.q1_attempt then 'Группа 1 (0-25%)'
        when ab.q2_attempt is not null and tf."Интервал (в часах)" <= ab.q2_attempt then 'Группа 2 (25-50%)'
        when ab.q3_attempt is not null and tf."Интервал (в часах)" <= ab.q3_attempt then 'Группа 3 (50-75%)'
        when ab.q3_attempt is not null then 'Группа 4 (75-100%)'
        else 'Недостаточно данных'
    end as группа_интервала_по_попытке,
    iq.группа_интервала_4 as группа_интервала_общая
from tt_final tf
left join attempt_quartile_boundaries ab
  on tf."CampaignId" = ab."CampaignId"
 and tf."Название МК" is not distinct from ab."Название МК"
 and tf."Канал" is not distinct from ab."Канал"
 and tf."Номер звонка внутри задачи" = ab.номер_попытки
left join tt_intervals_with_quartiles iq
  on tf."Task_Id" = iq."Task_Id"
 and tf."call_id" = iq."call_id"
where tf."Интервал (в часах)" is not null
  and tf."Номер звонка внутри задачи" > 1;

create index on tt_by_attempt_and_interval ("Канал", номер_попытки, группа_интервала_по_попытке);
analyze tt_by_attempt_and_interval;


--=========================================================================
-- ТАБЛИЦА 1: Распределение по номерам попыток
--=========================================================================
select
    'Распределение по номерам попыток' as "Анализ",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Группа интервала",
    count(*) as "Кол-во интервалов",
    sum(успешное_соединение) as "Успешных соединений",
    round(100.0 * sum(успешное_соединение) / count(*), 2) as "Доля успешных соединений",
    round(avg(интервал_часы)::numeric, 3) as "Средний интервал (часы)",
    min(интервал_часы) as "Мин интервал",
    max(интервал_часы) as "Макс интервал"
from tt_by_attempt_and_interval
where группа_интервала_по_попытке != 'Недостаточно данных'
group by номер_попытки, группа_интервала_по_попытке
order by
    номер_попытки,
    case группа_интервала_по_попытке
        when 'Группа 1 (0-25%)' then 1
        when 'Группа 2 (25-50%)' then 2
        when 'Группа 3 (50-75%)' then 3
        when 'Группа 4 (75-100%)' then 4
    end;


--=========================================================================
-- ТАБЛИЦА 2: Детальный анализ по МК и номерам попыток
--=========================================================================
select
    'Детально по МК и попыткам' as "Анализ",
    "Название МК",
    "Канал",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Группа интервала",
    всего_интервалов_в_группе as "Всего интервалов в группе МК+попытка",
    count(*) as "Кол-во в данной группе",
    round(100.0 * count(*) / nullif(всего_интервалов_в_группе, 0), 2) as "% от группы",
    sum(успешное_соединение) as "Успешных",
    round(100.0 * sum(успешное_соединение) / count(*), 2) as "Доля успешных",
    round(avg(интервал_часы)::numeric, 3) as "Ср. интервал"
from tt_by_attempt_and_interval
where группа_интервала_по_попытке != 'Недостаточно данных'
group by
    "Название МК", "Канал", номер_попытки, группа_интервала_по_попытке, всего_интервалов_в_группе
order by
    "Название МК", номер_попытки,
    case группа_интервала_по_попытке
        when 'Группа 1 (0-25%)' then 1
        when 'Группа 2 (25-50%)' then 2
        when 'Группа 3 (50-75%)' then 3
        when 'Группа 4 (75-100%)' then 4
    end;


--=========================================================================
-- ТАБЛИЦА 5: Лучшие интервалы для каждой МК и попытки (Входящий канал)
--=========================================================================
with ranked_by_mk_and_attempt as (
    select
        "Название МК",
        "Канал",
        номер_попытки,
        группа_интервала_по_попытке,
        count(*) as всего_интервалов,
        sum(успешное_соединение) as успешных,
        round(100.0 * sum(успешное_соединение) / count(*), 2) as доля_успешных,
        round(percentile_cont(0.5) within group (order by интервал_часы)::numeric, 3) as медиана_интервала_часы,
        row_number() over (
            partition by "Название МК", номер_попытки
            order by round(100.0 * sum(успешное_соединение) / count(*), 2) desc
        ) as rn
    from tt_by_attempt_and_interval
    where группа_интервала_по_попытке != 'Недостаточно данных'
      and "Канал" = 'Входящий'
    group by "Название МК", "Канал", номер_попытки, группа_интервала_по_попытке
    having count(*) >= 30
)
select
    'Оптимальные интервалы по МК и попыткам для Входящего канала' as "Анализ",
    "Название МК",
    "Канал",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Оптимальная группа",
    всего_интервалов as "Всего",
    успешных as "Успешных",
    доля_успешных || '%' as "Успешность",
    медиана_интервала_часы as "Медиана (часы)",
    round((медиана_интервала_часы * 60)::numeric, 1) as "Медиана (минуты)"
from ranked_by_mk_and_attempt
where rn = 1
order by "Название МК", номер_попытки;


--=========================================================================
-- ТАБЛИЦА 6: Сводный анализ по Исходящему каналу (без деления по МК)
--=========================================================================
with outbound_analysis as (
    select
        номер_попытки,
        группа_интервала_по_попытке,
        count(*) as всего_интервалов,
        sum(успешное_соединение) as успешных,
        round(100.0 * sum(успешное_соединение) / count(*), 2) as доля_успешных,
        round(avg(интервал_часы)::numeric, 3) as средний_интервал,
        round(percentile_cont(0.5) within group (order by интервал_часы)::numeric, 3) as медиана_интервала,
        min(интервал_часы) as мин_интервал,
        max(интервал_часы) as макс_интервал,
        count(distinct "Название МК") as кол_во_мк
    from tt_by_attempt_and_interval
    where группа_интервала_по_попытке != 'Недостаточно данных'
      and "Канал" = 'Исходящий'
    group by номер_попытки, группа_интервала_по_попытке
    having count(*) >= 30
)
select
    'Сводный анализ по Исходящему каналу' as "Анализ",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Группа интервала",
    всего_интервалов as "Всего интервалов",
    кол_во_мк as "Кол-во МК",
    успешных as "Успешных",
    доля_успешных || '%' as "Доля успешных",
    средний_интервал as "Средний интервал (часы)",
    медиана_интервала as "Медиана (часы)",
    round((медиана_интервала * 60)::numeric, 1) as "Медиана (минуты)",
    мин_интервал as "Мин (часы)",
    макс_интервал as "Макс (часы)"
from outbound_analysis
order by
    номер_попытки,
    case группа_интервала_по_попытке
        when 'Группа 1 (0-25%)' then 1
        when 'Группа 2 (25-50%)' then 2
        when 'Группа 3 (50-75%)' then 3
        when 'Группа 4 (75-100%)' then 4
    end;


--=========================================================================
-- ТАБЛИЦА 7: Оптимальные интервалы для Исходящего канала
--=========================================================================
with best_outbound as (
    select
        номер_попытки,
        группа_интервала_по_попытке,
        count(*) as всего_звонков,
        count(distinct "Название МК") as кол_во_мк,
        round(100.0 * sum(успешное_соединение) / count(*), 2) as успешность,
        round(percentile_cont(0.5) within group (order by интервал_часы)::numeric, 3) as медиана_интервала,
        row_number() over (
            partition by номер_попытки
            order by round(100.0 * sum(успешное_соединение) / count(*), 2) desc
        ) as rn
    from tt_by_attempt_and_interval
    where группа_интервала_по_попытке != 'Недостаточно данных'
      and "Канал" = 'Исходящий'
    group by номер_попытки, группа_интервала_по_попытке
    having count(*) >= 30
)
select
    'Оптимальные интервалы для Исходящего канала' as "Анализ",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Оптимальная группа",
    всего_звонков as "Всего звонков",
    кол_во_мк as "Кол-во МК",
    успешность || '%' as "Успешность",
    медиана_интервала as "Медиана (часы)",
    round((медиана_интервала * 60)::numeric, 1) as "Медиана (минуты)"
from best_outbound
where rn = 1
order by номер_попытки;


--=========================================================================
-- НОВЫЕ ОТЧЁТЫ: redial по предыдущему исходу
--=========================================================================
drop table if exists tt_redial_base;
create temp table tt_redial_base as
with base as (
    select
        cn."Task_Id",
        cn."call_id",
        cn.interaction_id,
        cn."Дата начала звонка",
        cn."Дата окончания звонка",
        cn."Номер телефона",
        cn."Тип звонка",
        cn.campaign as "CampaignId",
        lc.name as "Название МК",
        cn."Номер звонка внутри задачи",
        case
            when lc.type = 1 then 'Исходящий'
            when lc.type = 3 and coalesce(cn.payload_type, '') != 'partners' then 'Входящий'
        end as "Канал",
        cr."Результат звонка",
        cr."Причина завершения звонка",
        cn."Интервал между звонками",
        cn."Интервал (в часах)",
        cn."Интервал в рамках дня",
        case
            when extract(hour from cn."Дата начала звонка") between 6 and 11 then 'Утро'
            when extract(hour from cn."Дата начала звонка") between 12 and 17 then 'День'
            when extract(hour from cn."Дата начала звонка") between 18 and 21 then 'Вечер'
            else 'Ночь'
        end as "Время суток звонка"
    from callnumbers cn
    left join voipclient.leasing_campaign lc
      on cn.campaign = lc.id
    left join callresults cr
      on cr."call_id" = cn."call_id"
),
with_prev as (
    select
        b.*,
        lag(b."Результат звонка") over (
            partition by b."Task_Id", b."Номер телефона"
            order by b."Номер звонка внутри задачи"
        ) as "Результат предыдущего звонка",
        lag(b."Причина завершения звонка") over (
            partition by b."Task_Id", b."Номер телефона"
            order by b."Номер звонка внутри задачи"
        ) as "Причина завершения предыдущего звонка"
    from base b
)
select
    w.*,
    case
        when w."Канал" = 'Исходящий' and w."Результат звонка" is null then 0
        when w."Причина завершения звонка" = 'Лизинг. Не удалось дозвониться' then 0
        when coalesce(w."Результат звонка", '') ilike '%Не удалось дозвониться%' then 0
        else 1
    end as is_success,
    case
        when w."Номер звонка внутри задачи" <= 1 then null
        when (
                (w."Канал" = 'Исходящий' and w."Результат предыдущего звонка" is null)
             or w."Причина завершения предыдущего звонка" = 'Лизинг. Не удалось дозвониться'
             or coalesce(w."Результат предыдущего звонка", '') ilike '%Не удалось дозвониться%'
        ) then 'A_no_answer'
        when (
                coalesce(w."Причина завершения предыдущего звонка", '') ilike '%Перезвонить позднее%'
             or coalesce(w."Результат предыдущего звонка", '') ilike '%Перезвонить позднее%'
        ) then 'B_callback_later'
        else 'C_other'
    end as prev_slice
from with_prev w;

create index on tt_redial_base ("Task_Id", "Номер телефона", "Номер звонка внутри задачи");
create index on tt_redial_base (prev_slice, "Канал");
create index on tt_redial_base ("call_id");
analyze tt_redial_base;


drop table if exists tt_redial_analysis;
create temp table tt_redial_analysis as
select *
from tt_redial_base
where "Номер звонка внутри задачи" > 1
  and "Интервал в рамках дня" = 1
  and "Интервал (в часах)" is not null
  and "Интервал (в часах)" > 0
  and prev_slice is not null;

create index on tt_redial_analysis (prev_slice, "Канал", "CampaignId", "Номер звонка внутри задачи");
analyze tt_redial_analysis;


drop table if exists tt_redial_with_q;
create temp table tt_redial_with_q as
with bounds as (
    select
        prev_slice,
        "Канал",
        "CampaignId",
        "Название МК",
        "Номер звонка внутри задачи" as номер_попытки,
        percentile_cont(0.25) within group (order by "Интервал (в часах)") as q1,
        percentile_cont(0.5)  within group (order by "Интервал (в часах)") as q2,
        percentile_cont(0.75) within group (order by "Интервал (в часах)") as q3,
        count(*) as всего_интервалов_в_группе
    from tt_redial_analysis
    group by
        prev_slice, "Канал", "CampaignId", "Название МК", "Номер звонка внутри задачи"
    having count(*) >= 30
)
select
    a.*,
    a."Номер звонка внутри задачи" as номер_попытки,
    a."Интервал (в часах)" as интервал_часы,
    b.q1, b.q2, b.q3,
    b.всего_интервалов_в_группе,
    case
        when b.q1 is not null and a."Интервал (в часах)" <= b.q1 then 'Группа 1 (0-25%)'
        when b.q2 is not null and a."Интервал (в часах)" <= b.q2 then 'Группа 2 (25-50%)'
        when b.q3 is not null and a."Интервал (в часах)" <= b.q3 then 'Группа 3 (50-75%)'
        when b.q3 is not null then 'Группа 4 (75-100%)'
        else 'Недостаточно данных'
    end as группа_интервала_по_попытке
from tt_redial_analysis a
left join bounds b
  on a.prev_slice = b.prev_slice
 and a."Канал" is not distinct from b."Канал"
 and a."CampaignId" = b."CampaignId"
 and a."Название МК" is not distinct from b."Название МК"
 and a."Номер звонка внутри задачи" = b.номер_попытки;

create index on tt_redial_with_q (prev_slice, "Канал", номер_попытки, группа_интервала_по_попытке);
analyze tt_redial_with_q;


--#########################################################################
-- ОТЧЁТ R1. Сводка по срезам (сколько строк попало в A / B / C)
-- Зачем: понять объём выборки перед сравнением интервалов.
--#########################################################################
select
    'R1. Объём по срезам предыдущего исхода' as "Анализ",
    prev_slice as "Срез",
    case prev_slice
        when 'A_no_answer' then 'После недозвона (вкл. NULL на исходящем)'
        when 'B_callback_later' then 'После «Перезвонить позднее»'
        when 'C_other' then 'Прочие предыдущие исходы'
    end as "Описание",
    "Канал",
    count(*) as "Кол-во интервалов",
    count(*) filter (where is_success = 1) as "Успешных",
    round(100.0 * count(*) filter (where is_success = 1) / nullif(count(*), 0), 2) as "Доля успешных %"
from tt_redial_analysis
group by prev_slice, "Канал"
order by prev_slice, "Канал";


--#########################################################################
-- ОТЧЁТ R2A. После недозвона — сетка попытка × квартиль (Исходящий)
--#########################################################################
select
    'R2A. После недозвона: попытка × группа (Исходящий)' as "Анализ",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Группа интервала",
    count(*) as "Кол-во интервалов",
    sum(is_success) as "Успешных",
    round(100.0 * sum(is_success) / count(*), 2) as "Доля успешных %",
    round(min(интервал_часы)::numeric, 3) as "Мин (часы)",
    round(percentile_cont(0.5) within group (order by интервал_часы)::numeric, 3) as "Медиана (часы)",
    round(max(интервал_часы)::numeric, 3) as "Макс (часы)",
    round((percentile_cont(0.5) within group (order by интервал_часы) * 60)::numeric, 1) as "Медиана (мин)"
from tt_redial_with_q
where prev_slice = 'A_no_answer'
  and "Канал" = 'Исходящий'
  and группа_интервала_по_попытке != 'Недостаточно данных'
group by номер_попытки, группа_интервала_по_попытке
order by
    номер_попытки,
    case группа_интервала_по_попытке
        when 'Группа 1 (0-25%)' then 1
        when 'Группа 2 (25-50%)' then 2
        when 'Группа 3 (50-75%)' then 3
        when 'Группа 4 (75-100%)' then 4
    end;


--#########################################################################
-- ОТЧЁТ R2B. После «Перезвонить позднее» — та же сетка (Исходящий)
--#########################################################################
select
    'R2B. После «Перезвонить позднее»: попытка × группа (Исходящий)' as "Анализ",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Группа интервала",
    count(*) as "Кол-во интервалов",
    sum(is_success) as "Успешных",
    round(100.0 * sum(is_success) / count(*), 2) as "Доля успешных %",
    round(min(интервал_часы)::numeric, 3) as "Мин (часы)",
    round(percentile_cont(0.5) within group (order by интервал_часы)::numeric, 3) as "Медиана (часы)",
    round(max(интервал_часы)::numeric, 3) as "Макс (часы)",
    round((percentile_cont(0.5) within group (order by интервал_часы) * 60)::numeric, 1) as "Медиана (мин)"
from tt_redial_with_q
where prev_slice = 'B_callback_later'
  and "Канал" = 'Исходящий'
  and группа_интервала_по_попытке != 'Недостаточно данных'
group by номер_попытки, группа_интервала_по_попытке
order by
    номер_попытки,
    case группа_интервала_по_попытке
        when 'Группа 1 (0-25%)' then 1
        when 'Группа 2 (25-50%)' then 2
        when 'Группа 3 (50-75%)' then 3
        when 'Группа 4 (75-100%)' then 4
    end;


--#########################################################################
-- ОТЧЁТ R2C. Прочие предыдущие исходы — та же сетка (Исходящий)
--#########################################################################
select
    'R2C. Прочие предыдущие исходы: попытка × группа (Исходящий)' as "Анализ",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Группа интервала",
    count(*) as "Кол-во интервалов",
    sum(is_success) as "Успешных",
    round(100.0 * sum(is_success) / count(*), 2) as "Доля успешных %",
    round(min(интервал_часы)::numeric, 3) as "Мин (часы)",
    round(percentile_cont(0.5) within group (order by интервал_часы)::numeric, 3) as "Медиана (часы)",
    round(max(интервал_часы)::numeric, 3) as "Макс (часы)",
    round((percentile_cont(0.5) within group (order by интервал_часы) * 60)::numeric, 1) as "Медиана (мин)"
from tt_redial_with_q
where prev_slice = 'C_other'
  and "Канал" = 'Исходящий'
  and группа_интервала_по_попытке != 'Недостаточно данных'
group by номер_попытки, группа_интервала_по_попытке
order by
    номер_попытки,
    case группа_интервала_по_попытке
        when 'Группа 1 (0-25%)' then 1
        when 'Группа 2 (25-50%)' then 2
        when 'Группа 3 (50-75%)' then 3
        when 'Группа 4 (75-100%)' then 4
    end;


--#########################################################################
-- ОТЧЁТ R3A. После недозвона — детально по МК (Исходящий)
--#########################################################################
select
    'R3A. После недозвона: МК × попытка × группа (Исходящий)' as "Анализ",
    "Название МК",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Группа интервала",
    всего_интервалов_в_группе as "Всего в МК+попытка",
    count(*) as "Кол-во в группе",
    sum(is_success) as "Успешных",
    round(100.0 * sum(is_success) / count(*), 2) as "Доля успешных %",
    round(avg(интервал_часы)::numeric, 3) as "Ср. интервал (часы)"
from tt_redial_with_q
where prev_slice = 'A_no_answer'
  and "Канал" = 'Исходящий'
  and группа_интервала_по_попытке != 'Недостаточно данных'
group by "Название МК", номер_попытки, группа_интервала_по_попытке, всего_интервалов_в_группе
order by
    "Название МК", номер_попытки,
    case группа_интервала_по_попытке
        when 'Группа 1 (0-25%)' then 1
        when 'Группа 2 (25-50%)' then 2
        when 'Группа 3 (50-75%)' then 3
        when 'Группа 4 (75-100%)' then 4
    end;


--#########################################################################
-- ОТЧЁТ R3B. После «Перезвонить позднее» — детально по МК (Исходящий)
--#########################################################################
select
    'R3B. После «Перезвонить позднее»: МК × попытка × группа (Исходящий)' as "Анализ",
    "Название МК",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Группа интервала",
    всего_интервалов_в_группе as "Всего в МК+попытка",
    count(*) as "Кол-во в группе",
    sum(is_success) as "Успешных",
    round(100.0 * sum(is_success) / count(*), 2) as "Доля успешных %",
    round(avg(интервал_часы)::numeric, 3) as "Ср. интервал (часы)"
from tt_redial_with_q
where prev_slice = 'B_callback_later'
  and "Канал" = 'Исходящий'
  and группа_интервала_по_попытке != 'Недостаточно данных'
group by "Название МК", номер_попытки, группа_интервала_по_попытке, всего_интервалов_в_группе
order by
    "Название МК", номер_попытки,
    case группа_интервала_по_попытке
        when 'Группа 1 (0-25%)' then 1
        when 'Группа 2 (25-50%)' then 2
        when 'Группа 3 (50-75%)' then 3
        when 'Группа 4 (75-100%)' then 4
    end;


--#########################################################################
-- ОТЧЁТ R4A. Кандидат после недозвона (Исходящий)
--#########################################################################
with ranked as (
    select
        номер_попытки,
        группа_интервала_по_попытке,
        count(*) as всего,
        sum(is_success) as успешных,
        round(100.0 * sum(is_success) / count(*), 2) as доля_успешных,
        round(min(интервал_часы)::numeric, 3) as мин_ч,
        round(percentile_cont(0.5) within group (order by интервал_часы)::numeric, 3) as медиана_ч,
        round(max(интервал_часы)::numeric, 3) as макс_ч,
        row_number() over (
            partition by номер_попытки
            order by round(100.0 * sum(is_success) / count(*), 2) desc, count(*) desc
        ) as rn
    from tt_redial_with_q
    where prev_slice = 'A_no_answer'
      and "Канал" = 'Исходящий'
      and группа_интервала_по_попытке != 'Недостаточно данных'
    group by номер_попытки, группа_интервала_по_попытке
    having count(*) >= 30
)
select
    'R4A. Кандидат после недозвона (Исходящий)' as "Анализ",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Лучшая группа",
    всего as "Всего",
    успешных as "Успешных",
    доля_успешных || '%' as "Успешность",
    мин_ч as "Вариант low (часы)",
    медиана_ч as "Вариант mid (часы)",
    макс_ч as "Вариант high (часы)",
    round((медиана_ч * 60)::numeric, 1) as "Вариант mid (мин)"
from ranked
where rn = 1
order by номер_попытки;


--#########################################################################
-- ОТЧЁТ R4B. Кандидат после «Перезвонить позднее» (Исходящий)
--#########################################################################
with ranked as (
    select
        номер_попытки,
        группа_интервала_по_попытке,
        count(*) as всего,
        sum(is_success) as успешных,
        round(100.0 * sum(is_success) / count(*), 2) as доля_успешных,
        round(min(интервал_часы)::numeric, 3) as мин_ч,
        round(percentile_cont(0.5) within group (order by интервал_часы)::numeric, 3) as медиана_ч,
        round(max(интервал_часы)::numeric, 3) as макс_ч,
        row_number() over (
            partition by номер_попытки
            order by round(100.0 * sum(is_success) / count(*), 2) desc, count(*) desc
        ) as rn
    from tt_redial_with_q
    where prev_slice = 'B_callback_later'
      and "Канал" = 'Исходящий'
      and группа_интервала_по_попытке != 'Недостаточно данных'
    group by номер_попытки, группа_интервала_по_попытке
    having count(*) >= 30
)
select
    'R4B. Кандидат после «Перезвонить позднее» (Исходящий)' as "Анализ",
    номер_попытки as "Номер попытки",
    группа_интервала_по_попытке as "Лучшая группа",
    всего as "Всего",
    успешных as "Успешных",
    доля_успешных || '%' as "Успешность",
    мин_ч as "Вариант low (часы)",
    медиана_ч as "Вариант mid (часы)",
    макс_ч as "Вариант high (часы)",
    round((медиана_ч * 60)::numeric, 1) as "Вариант mid (мин)"
from ranked
where rn = 1
order by номер_попытки;


--#########################################################################
-- ОТЧЁТ R5. Сравнение кандидатов A vs B
--#########################################################################
with cand as (
    select
        prev_slice,
        номер_попытки,
        группа_интервала_по_попытке,
        count(*) as всего,
        round(100.0 * sum(is_success) / count(*), 2) as доля_успешных,
        round(percentile_cont(0.5) within group (order by интервал_часы)::numeric, 3) as медиана_ч,
        row_number() over (
            partition by prev_slice, номер_попытки
            order by round(100.0 * sum(is_success) / count(*), 2) desc, count(*) desc
        ) as rn
    from tt_redial_with_q
    where prev_slice in ('A_no_answer', 'B_callback_later')
      and "Канал" = 'Исходящий'
      and группа_интервала_по_попытке != 'Недостаточно данных'
    group by prev_slice, номер_попытки, группа_интервала_по_попытке
    having count(*) >= 30
)
select
    'R5. Сравнение кандидатов: недозвон vs перезвонить позднее' as "Анализ",
    номер_попытки as "Номер попытки",
    max(case when prev_slice = 'A_no_answer' then группа_интервала_по_попытке end) as "Группа после недозвона",
    max(case when prev_slice = 'A_no_answer' then доля_успешных end) as "Успешность % после недозвона",
    max(case when prev_slice = 'A_no_answer' then медиана_ч end) as "Медиана ч после недозвона",
    max(case when prev_slice = 'B_callback_later' then группа_интервала_по_попытке end) as "Группа после перезвонить",
    max(case when prev_slice = 'B_callback_later' then доля_успешных end) as "Успешность % после перезвонить",
    max(case when prev_slice = 'B_callback_later' then медиана_ч end) as "Медиана ч после перезвонить"
from cand
where rn = 1
group by номер_попытки
order by номер_попытки;
