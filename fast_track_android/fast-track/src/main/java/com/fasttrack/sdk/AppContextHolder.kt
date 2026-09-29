package com.fasttrack.sdk

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.net.Uri

/**
 * 进程启动时由系统创建，自动挂载 Application Context，
 * 使 [FastTracker.init] 无需再传 context。
 */
class FastTrackContextProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        val ctx = context?.applicationContext ?: return false
        AppContextHolder.install(ctx)
        return true
    }

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? = null

    override fun getType(uri: Uri): String? = null

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int = 0
}

internal object AppContextHolder {
    @Volatile
    private var appContext: Context? = null

    fun install(context: Context) {
        if (appContext == null) {
            appContext = context.applicationContext
        }
    }

    fun getOrNull(): Context? = appContext

    fun require(): Context {
        return appContext
            ?: error(
                "FastTracker Application Context 未就绪。" +
                    "请确认已依赖 fast-track（会自动注册 ContentProvider），" +
                    "或调用 FastTracker.init(context, url, …) 显式传入。",
            )
    }
}
