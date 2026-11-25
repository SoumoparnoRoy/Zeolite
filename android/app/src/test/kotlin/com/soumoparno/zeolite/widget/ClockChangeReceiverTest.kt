package com.soumoparno.zeolite.widget

import java.io.File
import java.time.LocalDateTime
import java.time.ZoneId
import javax.xml.parsers.DocumentBuilderFactory
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class ClockChangeReceiverTest {

    private val android = "http://schemas.android.com/apk/res/android"

    /** Every manifest receiver's actions, by its name as written there. */
    private fun receiverActions(): Map<String, Set<String>> {
        // Gradle runs unit tests from the module folder.
        val manifest = DocumentBuilderFactory.newInstance()
            .apply { isNamespaceAware = true }
            .newDocumentBuilder()
            .parse(File("src/main/AndroidManifest.xml"))
        val receivers = manifest.getElementsByTagName("receiver")
        return (0 until receivers.length).associate { index ->
            val receiver = receivers.item(index) as Element
            val actions = receiver.getElementsByTagName("action")
            receiver.getAttributeNS(android, "name") to (0 until actions.length)
                .map { (actions.item(it) as Element).getAttributeNS(android, "name") }
                .toSet()
        }
    }

    // A widget only redraws when something wakes it. With the app closed, a
    // clock or zone set by hand woke nothing, and the Today widget showed
    // Friday's classes, with live buttons, on a Wednesday.
    @Test
    fun `a clock or zone change wakes the widgets with the app closed`() {
        val woken = receiverActions().filterValues {
            it.containsAll(setOf("android.intent.action.TIME_SET", "android.intent.action.TIMEZONE_CHANGED"))
        }
        assertEquals(setOf(".widget.ClockChangeReceiver"), woken.keys)
        assertTrue(woken.values.single().containsAll(ClockChangeReceiver.ACTIONS))
    }

    private val kolkata = ZoneId.of("Asia/Kolkata")
    private val kiritimati = ZoneId.of("Pacific/Kiritimati")

    // Pushed on Wed 25 Nov 2026: Wednesday to Tuesday.
    private val week = JSONObject(
        """{"days": [${(25..30).joinToString { """{"date": 202611$it}""" }}, {"date": 20261201}]}""",
    )

    private fun at(date: String, time: String, zone: ZoneId) =
        LocalDateTime.parse("${date}T$time").atZone(zone).toInstant().toEpochMilli()

    private fun midnights(zone: ZoneId, vararg dates: String) =
        dates.map { at(it, "00:00", zone) }

    @Test
    fun `the date set back re-arms every pushed midnight still ahead`() {
        // The clock went forward to Friday, which spent Thursday's and
        // Friday's midnights, then back to Wednesday afternoon.
        val now = at("2026-11-25", "16:47", kolkata)
        assertEquals(
            midnights(
                kolkata,
                "2026-11-26", "2026-11-27", "2026-11-28", "2026-11-29",
                "2026-11-30", "2026-12-01", "2026-12-02",
            ),
            ClockChangeReceiver.redrawTimes(week, null, now, kolkata),
        )
    }

    @Test
    fun `a new zone gets its own midnights`() {
        // Thursday 01:18 in Kiritimati is still Wednesday in Kolkata.
        val now = at("2026-11-26", "01:18", kiritimati)
        val times = ClockChangeReceiver.redrawTimes(week, null, now, kiritimati)
        assertEquals(at("2026-11-27", "00:00", kiritimati), times.first())
        assertEquals(at("2026-12-02", "00:00", kiritimati), times.last())
    }

    @Test
    fun `the stats widget also redraws at each class start still ahead`() {
        val now = at("2026-11-25", "16:47", kolkata)
        val nine = at("2026-11-26", "09:00", kolkata)
        val standing = JSONObject(
            """{"upcoming": [{"at": ${at("2026-11-25", "13:00", kolkata)}}, {"at": $nine}]}""",
        )
        val times = ClockChangeReceiver.redrawTimes(week, standing, now, kolkata)
        assertTrue(nine in times)
        assertEquals(8, times.size)
        assertEquals(times.sorted(), times)
    }

    @Test
    fun `nothing pushed means nothing to arm`() {
        assertEquals(emptyList<Long>(), ClockChangeReceiver.redrawTimes(null, null, 0, kolkata))
        assertEquals(
            emptyList<Long>(),
            ClockChangeReceiver.redrawTimes(JSONObject("""{"days": [{"date": 0}]}"""), null, 0, kolkata),
        )
    }
}
