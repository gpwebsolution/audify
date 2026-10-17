package com.example.music_app

import android.content.Intent
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : AudioServiceActivity() {

    private lateinit var mediaDelete: MediaDeleteHandler

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Um handler por canal — a lógica vive nos arquivos ao lado; a
        // Activity só registra e repassa o resultado do diálogo de exclusão.
        VideoQueryHandler(this, flutterEngine).register()
        GalleryQueryHandler(this, flutterEngine).register()
        PdfQueryHandler(this, flutterEngine).register()
        mediaDelete = MediaDeleteHandler(this, flutterEngine)
        mediaDelete.register()
        FileQueryHandler(this, flutterEngine).register()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        mediaDelete.onActivityResult(requestCode, resultCode, data)
    }
}
