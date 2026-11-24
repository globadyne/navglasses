package com.tzglasses.hud.core

import org.junit.Assert.assertTrue
import org.junit.Test

class CoreTest {
  @Test
  fun coreChecksPass() {
    for (seed in 1L..10L) {
      val failed = runCoreChecks(seed).filterNot { it.second }.map { it.first }
      assertTrue("Seed $seed failed: $failed", failed.isEmpty())
    }
  }
}
