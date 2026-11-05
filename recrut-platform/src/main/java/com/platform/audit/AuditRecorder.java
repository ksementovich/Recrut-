package com.platform.audit;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Component;

/**
 * Пишет в append-only журнал аудита. Вызывать в той же транзакции, что и изменение,
 * тогда запись аудита и само изменение либо фиксируются вместе, либо откатываются вместе.
 */
@Component
public class AuditRecorder {

    private final JdbcClient jdbc;
    private final ObjectMapper json;

    public AuditRecorder(JdbcClient jdbc, ObjectMapper json) {
        this.jdbc = jdbc;
        this.json = json;
    }

    public void record(UUID orgId, UUID actorId, String entity, String entityId,
                       String action, Object before, Object after) {
        jdbc.sql("""
                insert into audit_event (org_id, actor_id, entity, entity_id, action, before_state, after_state)
                values (:org, :actor, :entity, :entityId, :action,
                        cast(:before as jsonb), cast(:after as jsonb))
                """)
                .param("org", orgId)
                .param("actor", actorId)
                .param("entity", entity)
                .param("entityId", entityId)
                .param("action", action)
                .param("before", toJson(before))
                .param("after", toJson(after))
                .update();
    }

    private String toJson(Object value) {
        if (value == null) {
            return null;
        }
        try {
            return json.writeValueAsString(value);
        } catch (JsonProcessingException e) {
            throw new IllegalStateException("Cannot serialize audit payload", e);
        }
    }
}
