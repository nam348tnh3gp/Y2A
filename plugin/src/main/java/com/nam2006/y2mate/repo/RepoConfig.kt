package com.nam2006.y2mate.repo

import android.content.pm.PackageManager

object RepoConfig {
    const val GITHUB_OWNER = "nam348tnh3gp"
    const val GITHUB_REPO = "Y2A"

    const val INDEX_URL = "https://$GITHUB_OWNER.github.io/$GITHUB_REPO/simple/"
    const val EXTRA_INDEX_URL = "https://pypi.flet.dev/simple/"
    const val EXTRA_INDEX_URL_2 = "https://pypi.org/simple/"
    const val TRUSTED_HOST = "$GITHUB_OWNER.github.io"

    const val APP_A_PACKAGE = "com.nam2006.y2mate"

    fun releasesUrl(): String =
        "https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/latest"

    fun appAInstalled(pkgMgr: PackageManager): Boolean = try {
        pkgMgr.getPackageInfo(APP_A_PACKAGE, 0)
        true
    } catch (_: Exception) {
        false
    }

    fun appAVersion(pkgMgr: PackageManager): String? = try {
        pkgMgr.getPackageInfo(APP_A_PACKAGE, 0).versionName
    } catch (_: Exception) {
        null
    }
}