package com.platform.study;

import com.platform.audit.AuditRecorder;
import com.platform.shared.Tenant;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

@Service
public class StudyService {

    private final JdbcClient jdbc;
    private final TransactionTemplate tx;
    private final AuditRecorder audit;

    public StudyService(JdbcClient jdbc, TransactionTemplate tx, AuditRecorder audit) {
        this.jdbc = jdbc;
        this.tx = tx;
        this.audit = audit;
    }

    public StudyView create(UUID orgId, UUID actorId, CreateStudyRequest req) {
        return tx.execute(status -> {
            Tenant.bind(jdbc, orgId);
            UUID id = UUID.randomUUID();

            jdbc.sql("""
                    insert into study (id, org_id, title, session_duration_min, target_n, created_by)
                    values (:id, :org, :title, :duration, :targetN, :actor)
                    """)
                    .param("id", id)
                    .param("org", orgId)
                    .param("title", req.title().trim())
                    .param("duration", req.sessionDurationMin())
                    .param("targetN", req.targetN())
                    .param("actor", actorId)
                    .update();

            StudyView view = findOne(id);
            audit.record(orgId, actorId, "study", id.toString(), "CREATE", null,
                    Map.of("title", view.title(), "status", view.status()));
            return view;
        });
    }

    public List<StudyView> list(UUID orgId) {
        return tx.execute(status -> {
            Tenant.bind(jdbc, orgId);
            return jdbc.sql("""
                    select id, title, status, session_duration_min, target_n
                      from study
                     order by created_at desc
                    """)
                    .query(ROW_MAPPER)
                    .list();
        });
    }

    private StudyView findOne(UUID id) {
        return jdbc.sql("""
                select id, title, status, session_duration_min, target_n
                  from study
                 where id = :id
                """)
                .param("id", id)
                .query(ROW_MAPPER)
                .single();
    }

    private static final RowMapper<StudyView> ROW_MAPPER = (rs, rowNum) -> new StudyView(
            rs.getObject("id", UUID.class),
            rs.getString("title"),
            rs.getString("status"),
            rs.getInt("session_duration_min"),
            rs.getInt("target_n"));
}
