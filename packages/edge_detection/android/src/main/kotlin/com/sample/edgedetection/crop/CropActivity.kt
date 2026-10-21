package com.sample.edgedetection.crop

import android.app.Activity
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.view.Gravity
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.widget.*
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.appcompat.widget.SwitchCompat
import com.sample.edgedetection.EdgeDetectionHandler
import com.sample.edgedetection.R
import com.sample.edgedetection.processor.*
import com.sample.edgedetection.view.PaperRectangle
import org.opencv.android.OpenCVLoader
import org.opencv.android.Utils
import org.opencv.core.Mat
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

/** One editor; image operations always originate from the untouched source. */
class CropActivity : AppCompatActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private val generation = AtomicInteger()
    private lateinit var image: ImageView
    private lateinit var overlay: PaperRectangle
    private lateinit var cropButton: Button
    private lateinit var rotateButton: Button
    private lateinit var retakeButton: Button
    private lateinit var filters: RadioGroup
    private lateinit var progress: ProgressBar
    private lateinit var shadowSwitch: SwitchCompat
    private var original: Bitmap? = null
    private var previewSource: Bitmap? = null
    private var displayed: Bitmap? = null
    private var corners = ScanGeometry.fullImage
    private var turns = 0
    private var filter = ScanFilter.ENHANCED
    private var reduceShadows = true
    // Accessed only on worker; preview and export use exactly the same analysis.
    private var enhancement: EnhancementProfile? = null
    private var enhancementCrop: List<ScanPoint>? = null
    private var editing = false
    private var busy = true
    private var saving = false
    private val labels = listOf(R.string.scanner_original, R.string.scanner_enhanced, R.string.scanner_grayscale, R.string.black)

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        title = getString(R.string.scanner_edit)
        supportActionBar?.setDisplayHomeAsUpEnabled(true)
        if (!OpenCVLoader.initDebug()) { finish(); return }
        val root = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; setBackgroundColor(Color.BLACK); setPadding(dp(16), dp(16), dp(16), dp(8)) }
        val frame = FrameLayout(this)
        image = ImageView(this).apply { scaleType = ImageView.ScaleType.FIT_CENTER; contentDescription = getString(R.string.scanner_edit) }
        overlay = PaperRectangle(this).apply { magnifierSource = image; contentDescription = getString(R.string.crop) }
        progress = ProgressBar(this)
        frame.addView(image, FrameLayout.LayoutParams(-1, -1)); frame.addView(overlay, FrameLayout.LayoutParams(-1, -1))
        frame.addView(progress, FrameLayout.LayoutParams(dp(48), dp(48), Gravity.CENTER))
        root.addView(frame, LinearLayout.LayoutParams(-1, 0, 1f))
        val scroll = HorizontalScrollView(this).apply { isHorizontalScrollBarEnabled = false }
        filters = RadioGroup(this).apply { orientation = RadioGroup.HORIZONTAL; gravity = Gravity.CENTER }
        labels.forEachIndexed { index, label -> filters.addView(RadioButton(this).apply {
            id = index + 100; text = getString(label); setTextColor(Color.WHITE); buttonTintList = android.content.res.ColorStateList.valueOf(Color.LTGRAY)
        }) }
        scroll.addView(filters); root.addView(scroll)
        reduceShadows = state?.getBoolean("reduceShadows", true) ?: true
        shadowSwitch = SwitchCompat(this).apply {
            text = getString(R.string.scanner_reduce_shadows); setTextColor(Color.WHITE)
            isChecked = reduceShadows; minHeight = dp(48)
            setOnCheckedChangeListener { _, checked -> reduceShadows = checked; if (!editing && original != null) requestPreview() }
        }
        root.addView(shadowSwitch, LinearLayout.LayoutParams(-1, dp(48)))
        val actions = LinearLayout(this).apply { gravity = Gravity.CENTER }
        retakeButton = Button(this).apply { text = getString(R.string.scanner_retake); setOnClickListener { if (editing) cancelCrop() else finish() } }
        cropButton = Button(this).apply { text = getString(R.string.crop); setOnClickListener { toggleCrop() } }
        rotateButton = Button(this).apply { text = getString(R.string.rotate); setOnClickListener { turns = (turns + 1) % 4; requestPreview() } }
        listOf(retakeButton, cropButton, rotateButton).forEach { actions.addView(it, LinearLayout.LayoutParams(0, dp(56), 1f)) }
        root.addView(actions); setContentView(root)
        turns = state?.getInt("turns") ?: 0
        filter = ScanFilter.values().getOrElse(state?.getInt("filter") ?: 1) { ScanFilter.ENHANCED }
        filters.check(100 + filter.ordinal)
        filters.setOnCheckedChangeListener { _, checked ->
            filter = ScanFilter.values()[(checked - 100).coerceIn(0, 3)]
            if (!editing && original != null) requestPreview() else setControls()
        }
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() { if (!saving) { if (editing) cancelCrop() else finish() } }
        })
        setControls()
        val restored = state?.getDoubleArray("corners")?.takeIf { it.size == 8 }?.let { data -> (0..3).map { ScanPoint(data[it * 2], data[it * 2 + 1]) } }?.takeIf { ScanGeometry.isValid(it) }
        val source = intent.getStringExtra("source")
        if (source == null) { finish(); return }
        worker.execute {
            try {
                val full = ScanImages.decode(File(source))
                val small = ScanImages.resize(full, 1200)
                val detectionSource = ScanImages.resize(full, 1600)
                val mat = Mat()
                val detected = try { Utils.bitmapToMat(detectionSource, mat); detectDocument(mat, maxEdge = 1600)?.points }
                    finally { mat.release(); if (detectionSource !== full && detectionSource !== small) detectionSource.recycle() }
                runOnUiThread {
                    if (isDestroyed || isFinishing) { if (small !== full) small.recycle(); full.recycle() }
                    else {
                        original = full; previewSource = small; corners = restored ?: detected ?: ScanGeometry.fullImage
                        overlay.setImageSize(small.width, small.height); requestPreview()
                    }
                }
            } catch (error: Exception) { runOnUiThread { showError(error, true) } }
        }
    }

    private fun requestPreview() {
        val source = previewSource ?: return
        val full = original ?: return
        val currentGeneration = generation.incrementAndGet()
        val crop = corners.toList(); val rotation = turns; val selected = filter; val shadows = reduceShadows
        busy = true; progress.visibility = View.VISIBLE; setControls()
        worker.execute {
            if (generation.get() != currentGeneration) return@execute
            try {
                val profile = if (selected == ScanFilter.ENHANCED && shadows) profileFor(full, crop) else null
                if (generation.get() != currentGeneration) return@execute
                val result = ScanImages.render(source, crop, rotation, selected, shadows, profile)
                runOnUiThread {
                    if (isDestroyed || isFinishing || generation.get() != currentGeneration) result.recycle()
                    else {
                        val old = displayed; displayed = result; image.setImageBitmap(result)
                        old?.recycle(); busy = false; progress.visibility = View.GONE; setControls()
                    }
                }
            } catch (error: Exception) { runOnUiThread { if (generation.get() == currentGeneration) showError(error) } }
        }
    }

    private fun profileFor(source: Bitmap, crop: List<ScanPoint>): EnhancementProfile {
        if (enhancementCrop != crop || enhancement == null) {
            enhancement?.close(); enhancement = null; enhancementCrop = null
            enhancement = ScanImages.prepareEnhancement(source, crop)
            enhancementCrop = crop.toList()
        }
        return enhancement!!
    }

    private fun toggleCrop() {
        if (busy || original == null) return
        if (editing) { corners = overlay.getPoints(); endCrop(); requestPreview() }
        else {
            editing = true; overlay.editing = true; overlay.setPoints(corners)
            image.setImageBitmap(previewSource); setControls()
        }
    }
    private fun cancelCrop() { endCrop(); requestPreview() }
    private fun endCrop() { editing = false; overlay.editing = false; overlay.setPoints(null) }

    private fun setControls() {
        cropButton.text = getString(if (editing) R.string.scanner_apply else R.string.crop)
        retakeButton.text = getString(if (editing) android.R.string.cancel else R.string.scanner_retake)
        cropButton.isEnabled = !busy && !saving
        rotateButton.isEnabled = !busy && !editing && !saving
        retakeButton.isEnabled = !saving
        shadowSwitch.visibility = if (filter == ScanFilter.ENHANCED && !editing) View.VISIBLE else View.GONE
        shadowSwitch.isEnabled = original != null && !saving
        for (i in 0 until filters.childCount) filters.getChildAt(i).isEnabled = original != null && !saving
        invalidateOptionsMenu()
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menu.add(0, 1, 0, R.string.save).setShowAsAction(MenuItem.SHOW_AS_ACTION_ALWAYS); return true
    }
    override fun onPrepareOptionsMenu(menu: Menu): Boolean {
        menu.findItem(1)?.isEnabled = !busy && !editing && !saving && original != null; return true
    }
    override fun onOptionsItemSelected(item: MenuItem): Boolean = when (item.itemId) {
        android.R.id.home -> { onBackPressedDispatcher.onBackPressed(); true }
        1 -> { save(); true }
        else -> super.onOptionsItemSelected(item)
    }

    private fun save() {
        val source = original ?: return
        if (saving || editing || busy) return
        val options = intent.getBundleExtra(EdgeDetectionHandler.INITIAL_BUNDLE)
        val destination = options?.getString(EdgeDetectionHandler.SAVE_TO) ?: return
        val crop = corners.toList(); val rotation = turns; val selected = filter; val shadows = reduceShadows
        saving = true; progress.visibility = View.VISIBLE; setControls()
        worker.execute {
            try {
                val profile = if (selected == ScanFilter.ENHANCED && shadows) profileFor(source, crop) else null
                val output = ScanImages.render(source, crop, rotation, selected, shadows, profile)
                try { ScanImages.save(output, File(destination)) } finally { output.recycle() }
                runOnUiThread { if (!isDestroyed) { setResult(Activity.RESULT_OK); finish() } }
            } catch (error: Exception) { runOnUiThread { saving = false; showError(error) } }
        }
    }

    private fun showError(error: Exception, fatal: Boolean = false) {
        if (isDestroyed || isFinishing) return
        busy = false; progress.visibility = View.GONE; setControls()
        AlertDialog.Builder(this).setMessage(error.localizedMessage ?: getString(R.string.scanner_read_error))
            .setPositiveButton(android.R.string.ok) { _, _ -> if (fatal) finish() }.setCancelable(!fatal).show()
    }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    override fun onSaveInstanceState(out: Bundle) {
        out.putDoubleArray("corners", corners.flatMap { listOf(it.x, it.y) }.toDoubleArray())
        out.putBoolean("reduceShadows", reduceShadows)
        out.putInt("turns", turns); out.putInt("filter", filter.ordinal); super.onSaveInstanceState(out)
    }
    override fun onDestroy() {
        generation.incrementAndGet(); if (::image.isInitialized) image.setImageDrawable(null)
        worker.execute { enhancement?.close(); displayed?.recycle(); if (previewSource !== original) previewSource?.recycle(); original?.recycle() }
        worker.shutdown(); super.onDestroy()
    }
}
