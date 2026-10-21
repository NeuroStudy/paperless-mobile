package com.sample.edgedetection.scan

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.graphics.BitmapFactory
import android.os.*
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import androidx.activity.result.ActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.view.PreviewView
import androidx.test.core.app.ActivityScenario
import androidx.test.espresso.Espresso.onView
import androidx.test.espresso.action.ViewActions.click
import androidx.test.espresso.matcher.ViewMatchers.withText
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry
import androidx.test.runner.lifecycle.Stage
import com.sample.edgedetection.EdgeDetectionHandler
import com.sample.edgedetection.R
import com.sample.edgedetection.crop.CropActivity
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

@RunWith(AndroidJUnit4::class)
class CameraWorkflowTest {
    @Test fun backCancelsScannerWithoutSaving() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.CAMERA)
        val destination = File.createTempFile("scan-cancel-result-", ".jpeg", context.cacheDir)
        val options = Bundle().apply { putString(EdgeDetectionHandler.SAVE_TO, destination.path) }
        val intent = Intent(context, ScanActivity::class.java)
            .putExtra(EdgeDetectionHandler.INITIAL_BUNDLE, options)
        try {
            // Exercise the real AndroidX result contract. ActivityScenario's legacy
            // BootstrapActivity result receiver can stall on API 36 during teardown.
            ActivityScenario.launch<ScannerResultHostActivity>(Intent(context, ScannerResultHostActivity::class.java)).use { scenario ->
                var host: ScannerResultHostActivity? = null
                scenario.onActivity { host = it; it.launchScanner(intent) }
                awaitMain {
                    val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<ScanActivity>().firstOrNull()
                    val preview = activity?.window?.decorView?.let { root -> descendants(root).filterIsInstance<PreviewView>().firstOrNull() }
                    preview?.previewStreamState?.value == PreviewView.StreamState.STREAMING
                }
                instrumentation.runOnMainSync {
                    ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED)
                        .filterIsInstance<ScanActivity>().first().onBackPressedDispatcher.onBackPressed()
                }
                awaitMain { host?.scanResult != null }
                assertEquals(Activity.RESULT_CANCELED, host!!.scanResult!!.resultCode)
                assertEquals(0L, destination.length())
            }
        } finally { destination.delete() }
    }

    @Test fun proportionalCameraCapturesAndSavesThroughTheEditor() {
        val instrumentation = InstrumentationRegistry.getInstrumentation()
        val context = instrumentation.targetContext
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.CAMERA)
        val destination = File.createTempFile("scan-camera-result-", ".jpeg", context.cacheDir)
        val options = Bundle().apply { putString(EdgeDetectionHandler.SAVE_TO, destination.path) }
        var scanner: ScanActivity? = null
        try {
            ActivityScenario.launch<ScanActivity>(Intent(context, ScanActivity::class.java).putExtra(EdgeDetectionHandler.INITIAL_BUNDLE, options)).use {
                awaitMain {
                    val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<ScanActivity>().firstOrNull()
                    val preview = activity?.window?.decorView?.let { root -> descendants(root).filterIsInstance<PreviewView>().firstOrNull() }
                    preview?.previewStreamState?.value == PreviewView.StreamState.STREAMING
                }
                instrumentation.runOnMainSync {
                    val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<ScanActivity>().first()
                    scanner = activity
                    val root = activity.window.decorView
                    val preview = descendants(root).filterIsInstance<PreviewView>().first()
                    val capture = descendants(root).filterIsInstance<Button>().first { button -> button.text == activity.getString(R.string.scanner_capture) }
                    val cameraPosition = IntArray(2); val controlPosition = IntArray(2)
                    preview.getLocationOnScreen(cameraPosition); capture.getLocationOnScreen(controlPosition)
                    assertTrue(preview.width < root.width)
                    assertTrue(cameraPosition[1] + preview.height <= controlPosition[1])
                    assertEquals(.75, preview.width.toDouble() / preview.height, .01)
                }
                val screenshot = instrumentation.uiAutomation.executeShellCommand("screencap -p /data/local/tmp/scanner-camera.png")
                ParcelFileDescriptor.AutoCloseInputStream(screenshot).use { stream -> stream.readBytes() }
                onView(withText(R.string.scanner_capture)).perform(click())
                awaitMain {
                    val activity = ActivityLifecycleMonitorRegistry.getInstance().getActivitiesInStage(Stage.RESUMED).filterIsInstance<CropActivity>().firstOrNull()
                    activity?.window?.decorView?.let { root -> descendants(root).filterIsInstance<Button>().any { button -> button.text == activity.getString(R.string.crop) && button.isEnabled } } ?: false
                }
                val cropPreview = instrumentation.uiAutomation.executeShellCommand("screencap -p /data/local/tmp/scanner-camera-crop-preview.png")
                ParcelFileDescriptor.AutoCloseInputStream(cropPreview).use { stream -> stream.readBytes() }
                onView(withText(R.string.save)).perform(click())
                awaitMain { destination.length() > 0 }
                awaitMain { scanner?.isDestroyed == true }
                instrumentation.waitForIdleSync()
                val output = BitmapFactory.decodeFile(destination.path)
                assertNotNull(output)
                assertTrue(output.width > 0 && output.height > 0)
                assertTrue(kotlin.math.max(output.width, output.height) <= 4096)
                output.recycle()
            }
        } finally { destination.delete() }
    }
    private fun descendants(view: View): List<View> = listOf(view) +
        if (view is ViewGroup) (0 until view.childCount).flatMap { descendants(view.getChildAt(it)) } else emptyList()
    private fun awaitMain(condition: () -> Boolean) {
        val done = CountDownLatch(1); val handler = Handler(Looper.getMainLooper())
        val check = object : Runnable {
            override fun run() { if (condition()) done.countDown() else handler.postDelayed(this, 50) }
        }
        handler.post(check)
        val completed = done.await(20, TimeUnit.SECONDS); handler.removeCallbacks(check)
        assertTrue("The camera/editor should become ready", completed)
    }
}

class ScannerResultHostActivity : AppCompatActivity() {
    var scanResult: ActivityResult? = null
        private set
    private val scanner = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { scanResult = it }
    fun launchScanner(intent: Intent) { scanner.launch(intent) }
}
