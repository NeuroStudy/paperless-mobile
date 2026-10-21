package com.sample.edgedetection.scan

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.view.Gravity
import android.view.MenuItem
import android.view.View
import android.widget.*
import androidx.activity.OnBackPressedCallback
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import com.sample.edgedetection.EdgeDetectionHandler
import com.sample.edgedetection.R
import com.sample.edgedetection.crop.CropActivity
import com.sample.edgedetection.processor.*
import com.sample.edgedetection.view.PaperRectangle
import org.opencv.android.OpenCVLoader
import org.opencv.core.Core
import org.opencv.core.CvType
import org.opencv.core.Mat
import java.io.File
import java.util.concurrent.Executors
import kotlin.math.min

class ScanActivity : AppCompatActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val tracker = DocumentTracker()
    private lateinit var preview: PreviewView
    private lateinit var overlay: PaperRectangle
    private lateinit var shutter: Button
    private lateinit var flash: ToggleButton
    private lateinit var options: Bundle
    private var provider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var capture: ImageCapture? = null
    private var pendingSource: File? = null
    @Volatile private var capturing = false
    private var lastFrame = 0L

    private val editor = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        pendingSource?.delete(); pendingSource = null; capturing = false; shutter.isEnabled = true
        if (result.resultCode == Activity.RESULT_OK) { setResult(Activity.RESULT_OK); finish() }
        else if (options.getBoolean(EdgeDetectionHandler.FROM_GALLERY)) finish()
        else preview.post { bindCamera() }
    }
    private val gallery = registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri == null) { if (options.getBoolean(EdgeDetectionHandler.FROM_GALLERY)) finish(); return@registerForActivityResult }
        capturing = true; shutter.isEnabled = false
        worker.execute {
            var source: File? = null
            try {
                source = File.createTempFile("scan-source-", ".image", cacheDir)
                contentResolver.openInputStream(uri).use { input ->
                    requireNotNull(input) { getString(R.string.scanner_read_error) }
                    source.outputStream().use { output -> input.copyTo(output) }
                }
                val imported = source
                runOnUiThread { if (isDestroyed || isFinishing) imported.delete() else openEditor(imported) }
            } catch (error: Exception) { source?.delete(); runOnUiThread { showError(error) } }
        }
    }

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        // A scanner cancellation must return to its caller, including on Android 16
        // where the default root-activity Back behavior can background the task.
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { setResult(Activity.RESULT_CANCELED); finish() }
        })
        options = intent.getBundleExtra(EdgeDetectionHandler.INITIAL_BUNDLE) ?: Bundle()
        title = options.getString(EdgeDetectionHandler.SCAN_TITLE, getString(R.string.scan))
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        if (!OpenCVLoader.initDebug()) { setResult(Activity.RESULT_CANCELED); finish(); return }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.BLACK); setPadding(dp(16), dp(16), dp(16), dp(8)) }
        // Keep the viewport proportional within the space above the controls.
        val space = object : FrameLayout(this) {
            override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
                super.onSizeChanged(w, h, oldw, oldh)
                val width = min(w, (h * 3.0 / 4.0).toInt())
                getChildAt(0)?.layoutParams = LayoutParams(width, width * 4 / 3, Gravity.CENTER)
            }
        }
        val viewport = FrameLayout(this)
        preview = PreviewView(this).apply { scaleType = PreviewView.ScaleType.FIT_CENTER; implementationMode = PreviewView.ImplementationMode.COMPATIBLE }
        overlay = PaperRectangle(this).apply { importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO }
        viewport.addView(preview, FrameLayout.LayoutParams(-1, -1)); viewport.addView(overlay, FrameLayout.LayoutParams(-1, -1))
        space.addView(viewport, FrameLayout.LayoutParams(-1, -1, Gravity.CENTER))
        root.addView(space, LinearLayout.LayoutParams(-1, 0, 1f))
        val controls = LinearLayout(this).apply { gravity = Gravity.CENTER; setPadding(0, dp(16), 0, dp(8)) }
        flash = ToggleButton(this).apply { textOn = getString(R.string.scanner_flash_on); textOff = getString(R.string.scanner_flash); isChecked = false
            setOnCheckedChangeListener { _, checked -> camera?.cameraControl?.enableTorch(checked) } }
        shutter = Button(this).apply { text = getString(R.string.scanner_capture); setOnClickListener { takePhoto() } }
        val import = Button(this).apply { text = getString(R.string.scanner_gallery); setOnClickListener { gallery.launch("image/*") }
            visibility = if (options.getBoolean(EdgeDetectionHandler.CAN_USE_GALLERY, true)) View.VISIBLE else View.GONE }
        controls.addView(flash, LinearLayout.LayoutParams(0, dp(56), 1f)); controls.addView(shutter, LinearLayout.LayoutParams(0, dp(56), 1f)); controls.addView(import, LinearLayout.LayoutParams(0, dp(56), 1f))
        root.addView(controls); setContentView(root)
        pendingSource = state?.getString("source")?.let { File(it) }
        if (state == null && options.getBoolean(EdgeDetectionHandler.FROM_GALLERY)) gallery.launch("image/*")
        preview.post { bindCamera() }
    }

    private fun bindCamera() {
        if (isFinishing || isDestroyed || capturing || options.getBoolean(EdgeDetectionHandler.FROM_GALLERY)) return
        val future = ProcessCameraProvider.getInstance(this)
        future.addListener({
            if (isDestroyed || isFinishing || capturing) return@addListener
            try {
                val cameraProvider = future.get(); provider = cameraProvider; cameraProvider.unbindAll()
                val rotation = preview.display.rotation
                val aspect = ResolutionSelector.Builder().setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY).build()
                val live = Preview.Builder().setResolutionSelector(aspect).setTargetRotation(rotation).build().also { it.setSurfaceProvider(preview.surfaceProvider) }
                capture = ImageCapture.Builder().setResolutionSelector(aspect).setTargetRotation(rotation)
                    .setCaptureMode(ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY).setJpegQuality(95).build()
                val resolution = ResolutionSelector.Builder().setAspectRatioStrategy(AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY)
                    .setResolutionStrategy(ResolutionStrategy(android.util.Size(960, 720), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER)).build()
                val analysis = ImageAnalysis.Builder().setResolutionSelector(resolution)
                    .setTargetRotation(rotation).setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                analysis.setAnalyzer(worker) { analyze(it) }
                val group = UseCaseGroup.Builder().addUseCase(live).addUseCase(capture!!).addUseCase(analysis)
                preview.viewPort?.let { group.setViewPort(it) }
                camera = cameraProvider.bindToLifecycle(this, CameraSelector.DEFAULT_BACK_CAMERA, group.build())
                flash.visibility = if (camera!!.cameraInfo.hasFlashUnit()) View.VISIBLE else View.INVISIBLE
                camera?.cameraControl?.enableTorch(flash.isChecked)
                worker.execute { tracker.reset() }
            } catch (error: Exception) { showError(error) }
        }, ContextCompat.getMainExecutor(this))
    }

    private fun analyze(image: ImageProxy) {
        var mat: Mat? = null
        try {
            val now = SystemClock.elapsedRealtime()
            if (capturing || now - lastFrame < 125 || !lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED)) return
            lastFrame = now
            val crop = image.cropRect; val plane = image.planes[0]; val buffer = plane.buffer.duplicate()
            val offset = buffer.position(); val bytes = ByteArray(crop.width() * crop.height())
            for (y in 0 until crop.height()) {
                val row = offset + (crop.top + y) * plane.rowStride + crop.left * plane.pixelStride
                if (plane.pixelStride == 1) { buffer.position(row); buffer.get(bytes, y * crop.width(), crop.width()) }
                else for (x in 0 until crop.width()) bytes[y * crop.width() + x] = buffer.get(row + x * plane.pixelStride)
            }
            mat = Mat(crop.height(), crop.width(), CvType.CV_8UC1).apply { put(0, 0, bytes) }
            when (image.imageInfo.rotationDegrees) {
                90 -> Core.rotate(mat, mat, Core.ROTATE_90_CLOCKWISE)
                180 -> Core.rotate(mat, mat, Core.ROTATE_180)
                270 -> Core.rotate(mat, mat, Core.ROTATE_90_COUNTERCLOCKWISE)
            }
            val dots = tracker.update(detectDocument(mat, tracker.points), now)
            val w = mat.cols(); val h = mat.rows()
            runOnUiThread { if (!isDestroyed && !capturing) { overlay.setImageSize(w, h); overlay.setPoints(dots) } }
        } catch (_: Exception) {
            tracker.reset(); runOnUiThread { if (!isDestroyed) overlay.setPoints(null) }
        } finally { mat?.release(); image.close() }
    }

    private fun takePhoto() {
        val output = capture ?: return
        if (capturing) return
        capturing = true; shutter.isEnabled = false
        val file = try { File.createTempFile("scan-source-", ".jpg", cacheDir) }
            catch (error: Exception) { showError(error); return }
        pendingSource = file
        output.takePicture(ImageCapture.OutputFileOptions.Builder(file).build(), ContextCompat.getMainExecutor(this), object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(result: ImageCapture.OutputFileResults) { if (isDestroyed || isFinishing) file.delete() else openEditor(file) }
            override fun onError(error: ImageCaptureException) { file.delete(); pendingSource = null; showError(error) }
        })
    }

    private fun openEditor(file: File) {
        pendingSource = file; capturing = true; provider?.unbindAll(); overlay.setPoints(null)
        editor.launch(Intent(this, CropActivity::class.java).putExtra(EdgeDetectionHandler.INITIAL_BUNDLE, options).putExtra("source", file.path))
    }
    private fun showError(error: Exception) {
        capturing = false
        if (isDestroyed || isFinishing) return
        shutter.isEnabled = true
        AlertDialog.Builder(this).setMessage(error.localizedMessage ?: getString(R.string.scanner_read_error)).setPositiveButton(android.R.string.ok, null).show()
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    override fun onSaveInstanceState(out: Bundle) { pendingSource?.let { out.putString("source", it.path) }; super.onSaveInstanceState(out) }
    override fun onOptionsItemSelected(item: MenuItem): Boolean { if (item.itemId == android.R.id.home) { finish(); return true }; return super.onOptionsItemSelected(item) }
    override fun onDestroy() { provider?.unbindAll(); worker.shutdown(); if (isFinishing) pendingSource?.delete(); super.onDestroy() }
}
