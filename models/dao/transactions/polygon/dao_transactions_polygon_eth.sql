{{ config(
    alias = 'transactions_polygon_eth',
    partition_by = ['block_date'],
    materialized = 'incremental',
    file_format = 'delta',
    incremental_strategy = 'merge',
    unique_key = ['block_date', 'blockchain', 'dao_creator_tool', 'dao', 'dao_wallet_address', 'tx_hash', 'tx_index', 'tx_type', 'trace_address', 'address_interacted_with', 'asset_contract_address', 'value']
    )
}}

{% set transactions_start_date = '2021-09-01' %}

WITH 

dao_tmp as (
        SELECT 
            blockchain, 
            dao_creator_tool, 
            dao, 
            dao_wallet_address
        FROM 
        {{ ref('dao_addresses_polygon') }}
        WHERE dao_wallet_address IS NOT NULL
), 

transactions as (
        SELECT 
            block_time, 
            tx_hash, 
            LOWER('0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee') as token, 
            value as value, 
            to as dao_wallet_address, 
            'tx_in' as tx_type, 
            tx_index,
            from as address_interacted_with,
            trace_address
        FROM 
        {{ source('polygon', 'traces') }}
        {% if not is_incremental() %}
        WHERE block_time >= '{{transactions_start_date}}'
        {% endif %}
        {% if is_incremental() %}
        WHERE block_time >= date_trunc("day", now() - interval '1 week')
        {% endif %}
        AND to IN (SELECT dao_wallet_address FROM dao_tmp)
        AND (LOWER(call_type) NOT IN ('delegatecall', 'callcode', 'staticcall') or call_type IS NULL)
        AND success = true 
        AND CAST(value as decimal(38,0)) != 0 

        UNION ALL 

        SELECT 
            block_time, 
            tx_hash, 
            LOWER('0xeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee') as token, 
            value as value, 
            from as dao_wallet_address, 
            'tx_out' as tx_type,
            tx_index,
            to as address_interacted_with,
            trace_address
        FROM 
        {{ source('polygon', 'traces') }}
        {% if not is_incremental() %}
        WHERE block_time >= '{{transactions_start_date}}'
        {% endif %}
        {% if is_incremental() %}
        WHERE block_time >= date_trunc("day", now() - interval '1 week')
        {% endif %}
        AND from IN (SELECT dao_wallet_address FROM dao_tmp)
        AND (LOWER(call_type) NOT IN ('delegatecall', 'callcode', 'staticcall') or call_type IS NULL)
        AND success = true 
        AND CAST(value as decimal(38,0)) != 0 
)

SELECT 
    dt.blockchain,
    dt.dao_creator_tool, 
    dt.dao, 
    dt.dao_wallet_address, 
    TRY_CAST(date_trunc('day', t.block_time) as DATE) as block_date, 
    t.block_time, 
    t.tx_type,
    t.token as asset_contract_address,
    'MATIC' as asset,
    t.value as raw_value, 
    t.value/POW(10, 18) as value, 
    t.value/POW(10, 18) * p.price as usd_value, 
    t.tx_hash, 
    t.tx_index,
    t.address_interacted_with,
    t.trace_address
FROM 
transactions t 
INNER JOIN 
dao_tmp dt 
    ON t.dao_wallet_address = dt.dao_wallet_address
LEFT JOIN 
{{ source('prices', 'usd') }} p 
    ON p.minute = date_trunc('minute', t.block_time)
    AND p.symbol = 'MATIC'
    AND p.blockchain = 'polygon'
    {% if not is_incremental() %}
    AND p.minute >= '{{transactions_start_date}}'
    {% endif %}
    {% if is_incremental() %}
    AND p.minute >= date_trunc("day", now() - interval '1 week')
    {% endif %}
