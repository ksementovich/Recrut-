package com.platform.budget;

import java.util.UUID;

public class BudgetLimitExceededException extends RuntimeException {

    private final UUID accountId;

    public BudgetLimitExceededException(UUID accountId) {
        super("Budget limit exceeded for account " + accountId);
        this.accountId = accountId;
    }

    public UUID getAccountId() {
        return accountId;
    }
}
