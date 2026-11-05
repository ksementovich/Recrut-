package com.platform.budget;

import com.platform.shared.Tenant;
import java.math.BigDecimal;
import java.util.List;
import java.util.UUID;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

/**
 * Резерв бюджета (раздел 4.3 архитектуры). Ключевая идея: условный UPDATE не даёт выйти за лимит
 * даже при параллельных запросах, а CHECK в БД — страховка на случай ошибки в коде.
 */
@Service
public class BudgetService {

    /** 0 строк = лимит исчерпан. Никакого SELECT-then-UPDATE. */
    private static final String RESERVE_SQL = """
            update budget_account
               set reserved_amount = reserved_amount + :amount,
                   version = version + 1
             where id = :id
               and limit_amount - reserved_amount - spent_amount >= :amount
            """;

    private static final String INSERT_ENTRY_SQL = """
            insert into budget_entry
                (org_id, account_id, type, amount, currency, ref_type, ref_id, idempotency_key, created_by)
            select org_id, id, 'RESERVE', :amount, currency, :refType, :refId, :key, :actor
              from budget_account
             where id = :id
            """;

    private static final String KEY_EXISTS_SQL =
            "select count(*) from budget_entry where idempotency_key = :key";

    private final JdbcClient jdbc;
    private final TransactionTemplate tx;

    public BudgetService(JdbcClient jdbc, TransactionTemplate tx) {
        this.jdbc = jdbc;
        this.tx = tx;
    }

    /**
     * Резервирует сумму на всех перечисленных счетах в одной транзакции.
     *
     * @param accountIds счета в фиксированном порядке блокировки: ORG, затем STUDY, затем CAMPAIGN.
     *                   Единый порядок исключает deadlock между параллельными резервами.
     * @return true, если резерв применён сейчас; false, если такая операция уже была применена (идемпотентность).
     * @throws BudgetLimitExceededException если хотя бы один счёт не может принять сумму (откат всей операции).
     */
    public boolean reserve(UUID orgId, UUID actorId, String opKey, BigDecimal amount,
                           String refType, UUID refId, List<UUID> accountIds) {
        if (accountIds.isEmpty()) {
            throw new IllegalArgumentException("accountIds must not be empty");
        }
        return tx.execute(status -> {
            Tenant.bind(jdbc, orgId);

            if (count(opKey + ":" + accountIds.get(0)) > 0) {
                return false;
            }

            for (UUID accountId : accountIds) {
                int updated = jdbc.sql(RESERVE_SQL)
                        .param("amount", amount)
                        .param("id", accountId)
                        .update();
                if (updated == 0) {
                    // RuntimeException откатит все предыдущие UPDATE этой транзакции
                    throw new BudgetLimitExceededException(accountId);
                }
                jdbc.sql(INSERT_ENTRY_SQL)
                        .param("amount", amount)
                        .param("refType", refType)
                        .param("refId", refId)
                        .param("key", opKey + ":" + accountId)
                        .param("actor", actorId)
                        .param("id", accountId)
                        .update();
            }
            return true;
        });
    }

    private long count(String key) {
        return jdbc.sql(KEY_EXISTS_SQL).param("key", key).query(Long.class).single();
    }
}
