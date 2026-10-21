package com.sample.edgedetection.crop

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.widget.Button
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.action.ViewActions.scrollTo
import androidx.test.espresso.assertion.ViewAssertions.matches
import androidx.test.espresso.matcher.ViewMatchers.*
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.sample.edgedetection.EdgeDetectionHandler
import com.sample.edgedetection.R
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class CropWorkflowTest {
    @Test fun cropApplyCancelAndFiltersShareOneEditorAndSave() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        val source = File.createTempFile("scan-workflow-", ".jpg", context.cacheDir)
        val destination = File.createTempFile("scan-workflow-result-", ".jpeg", context.cacheDir)
        val bitmap = Bitmap.createBitmap(600, 800, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap); canvas.drawColor(Color.DKGRAY)
        canvas.drawRect(60f, 65f, 540f, 735f, Paint().apply { color = Color.WHITE })
        canvas.drawText("Invoice 1234", 100f, 180f, Paint().apply { color = Color.BLACK; textSize = 36f })
        source.outputStream().use { bitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }; bitmap.recycle()
        val options = Bundle().apply { putString(EdgeDetectionHandler.SAVE_TO, destination.path) }
        val intent = Intent(context, CropActivity::class.java).putExtra("source", source.path).putExtra(EdgeDetectionHandler.INITIAL_BUNDLE, options)
        try {
            ActivityScenario.launch<CropActivity>(intent).use { scenario ->
                awaitReady(scenario)
                onView(withText(R.string.scanner_reduce_shadows)).check(matches(isChecked())).perform(click())
                awaitReady(scenario)
                onView(withText(R.string.scanner_reduce_shadows)).check(matches(isNotChecked()))
                scenario.recreate()
                awaitReady(scenario)
                onView(withText(R.string.scanner_reduce_shadows)).check(matches(isNotChecked())).perform(click())
                awaitReady(scenario)
                onView(withText(R.string.crop)).perform(click())
                capture("scanner-crop.png")
                onView(withText(R.string.scanner_apply)).check(matches(isDisplayed())).perform(click())
                awaitReady(scenario)
                onView(withText(R.string.crop)).perform(click())
                onView(withText(android.R.string.cancel)).perform(click())
                awaitReady(scenario)
                onView(withText(R.string.rotate)).perform(click())
                awaitReady(scenario)
                onView(withText(R.string.scanner_grayscale)).perform(scrollTo(), click())
                awaitReady(scenario)
                onView(withText(R.string.scanner_reduce_shadows)).check(matches(withEffectiveVisibility(Visibility.GONE)))
                capture("scanner-editor.png")
                onView(withText(R.string.save)).perform(click())
                val saved = CountDownLatch(1)
                val handler = Handler(Looper.getMainLooper())
                val check = object : Runnable {
                    override fun run() { if (destination.length() > 0) saved.countDown() else handler.postDelayed(this, 30) }
                }
                handler.post(check)
                assertTrue("Saving should produce a scan", saved.await(10, TimeUnit.SECONDS)); handler.removeCallbacks(check)
            }
            val output = BitmapFactory.decodeFile(destination.path)
            assertNotNull(output); assertTrue("Rotation should be retained", output.width > output.height)
            val color = output.getPixel(output.width / 2, output.height / 2)
            assertTrue(kotlin.math.abs(Color.red(color) - Color.green(color)) <= 2)
            output.recycle()
        } finally { source.delete(); destination.delete() }
    }

    private fun awaitReady(scenario: ActivityScenario<CropActivity>) {
        val ready = CountDownLatch(1)
        val handler = Handler(Looper.getMainLooper())
        val check = object : Runnable {
            override fun run() {
                scenario.onActivity { activity ->
                    val root = activity.window.decorView
                    val buttons = ArrayList<android.view.View>(); root.findViewsWithText(buttons, activity.getString(R.string.crop), android.view.View.FIND_VIEWS_WITH_TEXT)
                    if (buttons.any { it is Button && it.isEnabled }) ready.countDown()
                }
                if (ready.count > 0) handler.postDelayed(this, 30)
            }
        }
        handler.post(check)
        assertTrue("Editor should finish rendering", ready.await(10, TimeUnit.SECONDS)); handler.removeCallbacks(check)
    }
    private fun capture(name: String) {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val command = instrumentation.uiAutomation.executeShellCommand("screencap -p /data/local/tmp/$name")
        ParcelFileDescriptor.AutoCloseInputStream(command).use { it.readBytes() }
    }
}
