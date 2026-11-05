package com.soumoparno.zeolite

import com.google.android.play.agesignals.AgeSignalsException
import com.google.android.play.agesignals.AgeSignalsRequest
import com.google.android.play.agesignals.AgeSignalsResult
import com.google.android.play.agesignals.model.AgeRangeSource
import com.google.android.play.agesignals.model.AgeSignalsErrorCode
import com.google.android.play.agesignals.model.AgeSignalsStatus
import com.google.android.play.agesignals.model.SignificantChangeStatus
import com.google.android.play.agesignals.testing.FakeAgeSignalsManager
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AgeSignalsBridgeTest {

    private fun replyFor(result: AgeSignalsResult): Map<String, Any?> {
        val manager = FakeAgeSignalsManager()
        manager.setNextAgeSignalsResult(result)
        return AgeSignalsBridge.shared(
            manager.checkAgeSignals(AgeSignalsRequest.builder().build()).result)
    }

    @Test
    fun `each source tier passes the bounds through unchanged`() {
        for (tier in listOf(
            AgeRangeSource.TIER_A, AgeRangeSource.TIER_B,
            AgeRangeSource.TIER_C, AgeRangeSource.TIER_D,
        )) {
            val minor = replyFor(AgeSignalsResult.builder()
                .setAgeRangeSource(tier).setAgeLower(13).setAgeUpper(15).build())
            assertEquals(mapOf("status" to "shared", "lower" to 13, "upper" to 15, "change" to null), minor)

            val adult = replyFor(AgeSignalsResult.builder()
                .setAgeRangeSource(tier).setAgeLower(18).build())
            assertEquals(mapOf("status" to "shared", "lower" to 18, "upper" to null, "change" to null), adult)
        }
    }

    @Test
    fun `every default band reaches the app`() {
        for ((lower, upper) in listOf(0 to 12, 13 to 15, 16 to 17)) {
            val reply = replyFor(AgeSignalsResult.builder()
                .setAgeRangeSource(AgeRangeSource.TIER_B).setAgeLower(lower).setAgeUpper(upper).build())
            assertEquals(lower, reply["lower"])
            assertEquals(upper, reply["upper"])
        }
    }

    @Test
    fun `a user who shares nothing comes back with no bounds`() {
        val reply = replyFor(AgeSignalsResult.builder().build())
        assertEquals(mapOf("status" to "shared", "lower" to null, "upper" to null, "change" to null), reply)
    }

    @Test
    fun `the install id never crosses the channel`() {
        val reply = replyFor(AgeSignalsResult.builder()
            .setAgeRangeSource(AgeRangeSource.TIER_B).setAgeLower(13).setAgeUpper(15)
            .setInstallId("fake_install_id_123").build())
        assertFalse(reply.values.contains("fake_install_id_123"))
        assertEquals(setOf("status", "lower", "upper", "change"), reply.keys)
    }

    @Test
    fun `significant change status is named`() {
        for ((status, name) in listOf(
            SignificantChangeStatus.APPROVED to "approved",
            SignificantChangeStatus.PENDING to "pending",
            SignificantChangeStatus.DECLINED to "declined",
        )) {
            val reply = replyFor(AgeSignalsResult.builder()
                .setAgeRangeSource(AgeRangeSource.TIER_B).setAgeLower(13).setAgeUpper(15)
                .setSignificantChangeStatus(status).build())
            assertEquals(name, reply["change"])
        }
    }

    @Test
    fun `not shared and verification required say so with nothing else`() {
        assertEquals(mapOf("status" to "not_shared"),
            AgeSignalsBridge.notShared(AgeSignalsStatus.NOT_SHARED))
        assertEquals(mapOf("status" to "verification_required"),
            AgeSignalsBridge.notShared(AgeSignalsStatus.VERIFICATION_REQUIRED))
        assertEquals(mapOf("status" to "not_shared"), AgeSignalsBridge.notShared(null))
    }

    @Test
    fun `every error code is a failed reply carrying the code`() {
        for (code in listOf(
            AgeSignalsErrorCode.API_NOT_AVAILABLE, AgeSignalsErrorCode.PLAY_STORE_NOT_FOUND,
            AgeSignalsErrorCode.NETWORK_ERROR, AgeSignalsErrorCode.PLAY_SERVICES_NOT_FOUND,
            AgeSignalsErrorCode.CANNOT_BIND_TO_SERVICE, AgeSignalsErrorCode.PLAY_STORE_VERSION_OUTDATED,
            AgeSignalsErrorCode.PLAY_SERVICES_VERSION_OUTDATED, AgeSignalsErrorCode.CLIENT_TRANSIENT_ERROR,
            AgeSignalsErrorCode.APP_NOT_OWNED, AgeSignalsErrorCode.SDK_VERSION_OUTDATED,
            AgeSignalsErrorCode.INTERNAL_ERROR,
        )) {
            val manager = FakeAgeSignalsManager()
            manager.setNextAgeSignalsException(AgeSignalsException(code))
            val task = manager.checkAgeSignals(AgeSignalsRequest.builder().build())
            assertEquals(mapOf("status" to "error", "code" to code),
                AgeSignalsBridge.failed(task.exception!!))
        }
    }

    @Test
    fun `any other failure is a failed reply without a code`() {
        assertEquals(mapOf("status" to "error", "code" to null),
            AgeSignalsBridge.failed(IllegalStateException("no binder")))
    }
}
