package com.soumoparno.zeolite

import android.app.Activity
import com.google.android.gms.tasks.Task
import com.google.android.play.agesignals.AgeSignalsAccessRequest
import com.google.android.play.agesignals.AgeSignalsException
import com.google.android.play.agesignals.AgeSignalsManager
import com.google.android.play.agesignals.AgeSignalsRequest
import com.google.android.play.agesignals.AgeSignalsResult
import com.google.android.play.agesignals.model.AgeSignalsStatus
import com.google.android.play.agesignals.model.SignificantChangeStatus

// Google Play's age range for the age question and the Settings lock. Only the
// bounds and the status cross the channel: installId stays unread here, since
// nothing in Zeolite may act on it (no server holds anything of an under-18).
// Nothing is logged.
class AgeSignalsBridge(private val manager: AgeSignalsManager) {

    fun check(activity: Activity, reply: (Map<String, Any?>) -> Unit) {
        val access = AgeSignalsAccessRequest.builder().setActivity(activity).build()
        on(manager.requestAgeSignalsAccess(access), reply) { result ->
            if (result.ageSignalsStatus() == AgeSignalsStatus.SHARED) {
                on(manager.checkAgeSignals(AgeSignalsRequest.builder().build()), reply) {
                    reply(shared(it))
                }
            } else {
                reply(notShared(result.ageSignalsStatus()))
            }
        }
    }

    // Both listeners run on the main thread, where a channel reply has to go.
    private fun <T> on(task: Task<T>, reply: (Map<String, Any?>) -> Unit, then: (T) -> Unit) {
        task.addOnSuccessListener(then).addOnFailureListener { reply(failed(it)) }
    }

    companion object {
        fun shared(result: AgeSignalsResult): Map<String, Any?> = mapOf(
            "status" to "shared",
            "lower" to result.ageLower(),
            "upper" to result.ageUpper(),
            "change" to when (result.significantChangeStatus()) {
                SignificantChangeStatus.APPROVED -> "approved"
                SignificantChangeStatus.PENDING -> "pending"
                SignificantChangeStatus.DECLINED -> "declined"
                else -> null
            },
        )

        fun notShared(status: Int?): Map<String, Any?> = mapOf(
            "status" to when (status) {
                AgeSignalsStatus.VERIFICATION_REQUIRED -> "verification_required"
                else -> "not_shared"
            },
        )

        // A reply rather than a channel error: every failure means the same
        // thing to the app (no signal), and the code is enough to tell a
        // sideloaded build (-9, APP_NOT_OWNED) from a missing Play Store.
        fun failed(error: Exception): Map<String, Any?> = mapOf(
            "status" to "error",
            "code" to (error as? AgeSignalsException)?.errorCode,
        )
    }
}
