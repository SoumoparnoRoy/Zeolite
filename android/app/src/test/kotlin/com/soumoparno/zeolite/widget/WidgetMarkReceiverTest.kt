package com.soumoparno.zeolite.widget

import com.soumoparno.zeolite.widget.WidgetMarkReceiver.Companion.REPEAT_WINDOW_MS
import com.soumoparno.zeolite.widget.WidgetMarkReceiver.Companion.STATUSES
import com.soumoparno.zeolite.widget.WidgetMarkReceiver.Companion.repeats
import com.soumoparno.zeolite.widget.WidgetMarkReceiver.Companion.shownSession
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WidgetMarkReceiverTest {

    // One day with two classes, in the shape the Dart push writes.
    private val today = JSONObject(
        """
        {"days": [{"date": 20261019, "classes": [
          {"subjectId": 4, "startMinutes": 540, "status": null},
          {"subjectId": 7, "startMinutes": 600, "status": "present"}
        ]}]}
        """,
    )

    @Test
    fun `a class the widget is showing is found`() {
        assertEquals("present", shownSession(today, 7, 20261019, 600)?.optString("status"))
        assertNotNull(shownSession(today, 4, 20261019, 540))
    }

    // The widget host fills in the URI, so it can name anything.
    @Test
    fun `a class or day the widget is not showing is refused`() {
        assertNull(shownSession(today, 4, 20261018, 540))
        assertNull(shownSession(today, 4, 20261019, 600))
        assertNull(shownSession(today, 99, 20261019, 540))
        assertNull(shownSession(null, 4, 20261019, 540))
    }

    @Test
    fun `only the statuses the app knows are marks`() {
        assertEquals(setOf("present", "absent", "cancelled"), STATUSES)
        assertFalse("" in STATUSES)
        assertFalse("Present" in STATUSES)
    }

    @Test
    fun `a second tap on the same button soon after the first is a repeat`() {
        val first = "4:20261019:540|present|1000"
        assertTrue(repeats(first, "4:20261019:540", "present", now = 1150))
        assertTrue(repeats(first, "4:20261019:540", "present", now = 1000 + REPEAT_WINDOW_MS - 1))
    }

    @Test
    fun `a later tap, another button or another class is not a repeat`() {
        val first = "4:20261019:540|present|1000"
        assertFalse(repeats(first, "4:20261019:540", "present", now = 1000 + REPEAT_WINDOW_MS))
        assertFalse(repeats(first, "4:20261019:540", "absent", now = 1150))
        assertFalse(repeats(first, "7:20261019:600", "present", now = 1150))
        assertFalse(repeats(null, "4:20261019:540", "present", now = 1150))
        assertFalse(repeats("garbage", "4:20261019:540", "present", now = 1150))
    }
}
