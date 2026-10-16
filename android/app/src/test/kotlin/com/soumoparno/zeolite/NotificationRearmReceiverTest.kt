package com.soumoparno.zeolite

import com.soumoparno.zeolite.NotificationRearmReceiver.Companion.isMissed
import com.soumoparno.zeolite.NotificationRearmReceiver.Companion.prune
import java.time.ZonedDateTime
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NotificationRearmReceiverTest {

    // 04:00 in India on a Thursday: the morning the burst was seen.
    private val now = ZonedDateTime.parse("2026-10-15T04:00+05:30[Asia/Kolkata]")
        .toInstant().toEpochMilli()

    @Test
    fun `a reminder whose time has passed is dropped, one still to come is kept`() {
        assertTrue(isMissed("2026-10-08T08:55", "Asia/Kolkata", repeats = false, now = now))
        assertTrue(isMissed("2026-10-15T04:00", "Asia/Kolkata", repeats = false, now = now))
        assertFalse(isMissed("2026-10-15T08:55", "Asia/Kolkata", repeats = false, now = now))
    }

    @Test
    fun `the time is read in the zone it was stored with`() {
        // 03:50 UTC is 09:20 in India, still to come at 04:00 there.
        assertFalse(isMissed("2026-10-15T03:50", "UTC", repeats = false, now = now))
        // 22:00 the evening before in UTC is 03:30 in India, already gone.
        assertTrue(isMissed("2026-10-14T22:00", "UTC", repeats = false, now = now))
    }

    @Test
    fun `a repeating entry is left for the plugin even when its first time has passed`() {
        assertFalse(isMissed("2026-10-01T20:00", "Asia/Kolkata", repeats = true, now = now))
    }

    @Test
    fun `an entry that cannot be read is kept rather than lost`() {
        assertFalse(isMissed("", "Asia/Kolkata", repeats = false, now = now))
        assertFalse(isMissed("2026-10-08T08:55", "", repeats = false, now = now))
        assertFalse(isMissed("8 Oct, 08:55", "Asia/Kolkata", repeats = false, now = now))
        assertFalse(isMissed("2026-10-08T08:55", "Not/A_Zone", repeats = false, now = now))
    }

    // Two entries as flutter_local_notifications 22.3.0 wrote them on the
    // emulator: a class reminder at 08:45 and the evening one at 20:00 on
    // 19 October. A field rename in a plugin upgrade fails these.
    private val record = javaClass.getResource("/scheduled_notifications.json")!!.readText()

    private fun at(time: String) =
        ZonedDateTime.parse("2026-10-19T$time+05:30[Asia/Kolkata]").toInstant().toEpochMilli()

    private fun ids(json: String) =
        JSONArray(json).let { array -> (0 until array.length()).map { array.getJSONObject(it).getInt("id") } }

    @Test
    fun `a real record loses the reminder that was missed and keeps the one to come`() {
        assertEquals(listOf(3009), ids(prune(record, at("12:00"))!!))
    }

    @Test
    fun `a record with nothing missed is left alone`() {
        assertNull(prune(record, at("08:00")))
    }

    @Test
    fun `a missed entry that repeats is kept`() {
        val repeating = JSONArray(record).apply { getJSONObject(0).put("repeatInterval", "daily") }
        assertNull(prune(repeating.toString(), at("12:00")))
    }
}
