package com.platform.shared;

import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;

/**
 * Привязывает организацию к текущей транзакции, чтобы сработала RLS (политика tenant_isolation).
 * set_config(..., is_local = true) действует только до конца транзакции, поэтому контекст не утекает
 * в соседние запросы из пула соединений.
 *
 * Вызывать только внутри транзакции (TransactionTemplate или @Transactional).
 */
public final class Tenant {

    private Tenant() {
    }

    public static void bind(JdbcClient jdbc, UUID orgId) {
        jdbc.sql("select set_config('app.org_id', :org, true)")
                .param("org", orgId.toString())
                .query(String.class)
                .single();
    }
}
