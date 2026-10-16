package com.soumoparno.zeolite

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver
import java.time.LocalDateTime
import java.time.ZoneId
import org.json.JSONArray
import org.json.JSONObject

/**
 * Takes the plugin's place after a reboot or an app update. The plugin re-arms
 * every alarm on its record and a past one fires at once; records outlive
 * their alarms on ROMs that drop them, so an update delivered a whole earlier
 * day of reminders together. Missed ones are dropped from the record first.
 */
class NotificationRearmReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        // The plugin ignores anything else too, and nothing else should prune.
        if (intent.action !in ACTIONS) return
        try {
            dropMissed(context, System.currentTimeMillis())
        } catch (error: Exception) {
            // Never at the cost of re-arming the rest; logged, since a plugin
            // upgrade that moves the record would bring the burst back silently.
            Log.w("Zeolite", "Could not drop missed notifications", error)
        }
        ScheduledNotificationBootReceiver().onReceive(context, intent)
    }

    private fun dropMissed(context: Context, now: Long) {
        val prefs = context.getSharedPreferences(RECORD, Context.MODE_PRIVATE)
        val pruned = prune(prefs.getString(RECORD, null) ?: return, now) ?: return
        // commit, not apply: the plugin reads the record straight after this.
        prefs.edit().putString(RECORD, pruned).commit()
    }

    internal companion object {
        /**
         * The record without its missed one-offs, or null when nothing was
         * dropped and it can be left as it is.
         */
        fun prune(record: String, now: Long): String? {
            val stored = JSONArray(record)
            val kept = JSONArray()
            for (index in 0 until stored.length()) {
                // A null in the record is dropped: the plugin would fail on it.
                val entry = stored.optJSONObject(index) ?: continue
                if (!isMissedEntry(entry, now)) kept.put(entry)
            }
            return if (kept.length() == stored.length()) null else kept.toString()
        }

        private fun isMissedEntry(entry: JSONObject, now: Long): Boolean = isMissed(
            at = entry.optString("scheduledDateTime"),
            zone = entry.optString("timeZoneName"),
            repeats = REPEATS.any { entry.has(it) && !entry.isNull(it) },
            now = now,
        )

        /**
         * A one-off whose time has passed. Repeating entries and anything this
         * cannot read are left for the plugin, which is what happened before.
         */
        fun isMissed(at: String, zone: String, repeats: Boolean, now: Long): Boolean {
            if (repeats || at.isEmpty() || zone.isEmpty()) return false
            val fireAt = runCatching {
                LocalDateTime.parse(at).atZone(ZoneId.of(zone)).toInstant().toEpochMilli()
            }.getOrNull() ?: return false
            return fireAt <= now
        }

        /**
         * The plugin's own preferences file and key (flutter_local_notifications
         * 22.3.0, `FlutterLocalNotificationsPlugin.SCHEDULED_NOTIFICATIONS`), and
         * the Gson field names of its `NotificationDetails`. Check both when
         * the plugin is upgraded: a rename here fails quietly back to the old
         * burst, never to lost reminders.
         */
        const val RECORD = "scheduled_notifications"

        /** The broadcasts the manifest gives this receiver, as the plugin's. */
        val ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )

        val REPEATS = listOf(
            "repeatInterval",
            "repeatIntervalMilliseconds",
            "matchDateTimeComponents",
            "scheduledNotificationRepeatFrequency",
        )
    }
}
