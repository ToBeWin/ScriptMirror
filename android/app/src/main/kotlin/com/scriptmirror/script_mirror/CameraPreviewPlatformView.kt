package com.scriptmirror.script_mirror

import android.content.Context
import android.view.View
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import androidx.camera.view.PreviewView

class CameraPreviewFactory(
    private val controller: NativeCaptureController,
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    override fun create(context: Context, viewId: Int, args: Any?): PlatformView =
        CameraPreviewPlatformView(context, controller)
}

class CameraPreviewPlatformView(
    context: Context,
    private val controller: NativeCaptureController,
) : PlatformView {
    private val layoutListener = View.OnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
        controller.onPreviewLayoutChanged(preview)
    }

    private val preview = PreviewView(context).apply {
        implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        scaleType = PreviewView.ScaleType.FILL_CENTER
    }

    init {
        preview.addOnLayoutChangeListener(layoutListener)
        controller.attachPreview(preview)
    }

    override fun getView() = preview

    override fun dispose() {
        preview.removeOnLayoutChangeListener(layoutListener)
        controller.detachPreview(preview)
    }
}
