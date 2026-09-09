package com.docdeck.officeconversion.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.concurrent.atomic.AtomicBoolean;
import org.junit.jupiter.api.Test;

class JobCancellationRegistryTest {
    @Test
    void cancellationBeforeProcessRegistrationIsDeliveredToTheProcess() {
        JobCancellationRegistry registry = new JobCancellationRegistry();
        AtomicBoolean destroyed = new AtomicBoolean();

        assertThat(registry.cancel("request-before-start")).isFalse();
        JobCancellationRegistry.Handle handle = registry.register(
                "request-before-start",
                () -> destroyed.set(true)
        );

        assertThat(handle.isCancelled()).isTrue();
        assertThat(destroyed.get()).isTrue();
    }

    @Test
    void cancellationOfAnActiveProcessIsIdempotent() {
        JobCancellationRegistry registry = new JobCancellationRegistry();
        AtomicBoolean destroyed = new AtomicBoolean();
        JobCancellationRegistry.Handle handle = registry.register(
                "active-request",
                () -> destroyed.set(true)
        );

        assertThat(registry.cancel("active-request")).isTrue();
        assertThat(registry.cancel("active-request")).isTrue();
        assertThat(handle.isCancelled()).isTrue();
        assertThat(destroyed.get()).isTrue();
    }

    @Test
    void duplicateRegistrationDoesNotReplaceTheOriginalProcessHandle() {
        JobCancellationRegistry registry = new JobCancellationRegistry();
        AtomicBoolean firstDestroyed = new AtomicBoolean();
        AtomicBoolean secondDestroyed = new AtomicBoolean();
        registry.register("duplicate", () -> firstDestroyed.set(true));

        assertThatThrownBy(() -> registry.register("duplicate", () -> secondDestroyed.set(true)))
                .isInstanceOf(IllegalStateException.class);
        assertThat(registry.cancel("duplicate")).isTrue();
        assertThat(firstDestroyed.get()).isTrue();
        assertThat(secondDestroyed.get()).isFalse();
    }

    @Test
    void completionCleanupCannotEraseAConcurrentCancelTombstone() {
        JobCancellationRegistry registry = new JobCancellationRegistry();
        AtomicBoolean firstDestroyed = new AtomicBoolean();
        JobCancellationRegistry.Handle first = registry.register(
                "reused-request",
                () -> firstDestroyed.set(true)
        );

        // A request that has just completed is removed before a late DELETE
        // can arrive. The tombstone must survive that old handle's cleanup so
        // a same-ID registration cannot silently miss the cancellation.
        registry.unregister("reused-request", first);
        assertThat(registry.cancel("reused-request")).isFalse();

        AtomicBoolean secondDestroyed = new AtomicBoolean();
        JobCancellationRegistry.Handle second = registry.register(
                "reused-request",
                () -> secondDestroyed.set(true)
        );

        assertThat(second.isCancelled()).isTrue();
        assertThat(firstDestroyed.get()).isFalse();
        assertThat(secondDestroyed.get()).isTrue();
    }
}
