import java.util.Properties
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
  alias(libs.plugins.android.application)
  alias(libs.plugins.jetbrains.kotlin.android)
  alias(libs.plugins.compose.compiler)
}

// Meta Wearables credentials live in android/local.properties (not committed):
//   mwdat_application_id=...
//   mwdat_client_token=...
// Leave them out while the glasses are in Developer Mode.
val localProperties = Properties().apply {
  val file = rootDir.resolve("local.properties")
  if (file.exists()) file.inputStream().use { load(it) }
}

android {
  namespace = "com.tzglasses.hud"
  compileSdk = 36

  defaultConfig {
    applicationId = "com.tzglasses.hud"
    minSdk = 31
    targetSdk = 36
    versionCode = 1
    versionName = "0.1"

    manifestPlaceholders["mwdat_application_id"] = localProperties.getProperty("mwdat_application_id", "")
    manifestPlaceholders["mwdat_client_token"] = localProperties.getProperty("mwdat_client_token", "")
  }

  buildTypes {
    release {
      isMinifyEnabled = true
      proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
    }
  }

  compileOptions {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
  }

  packaging { resources { excludes += "/META-INF/{AL2.0,LGPL2.1}" } }
}

kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_17 } }

dependencies {
  implementation(libs.androidx.activity.compose)
  implementation(platform(libs.androidx.compose.bom))
  implementation(libs.androidx.lifecycle.runtime.compose)
  implementation(libs.androidx.lifecycle.viewmodel.compose)
  implementation(libs.androidx.material3)
  implementation(libs.mwdat.core)
  implementation(libs.mwdat.display)
  implementation(libs.mwdat.motion)
  implementation(libs.mwdat.inputs)
  implementation(libs.mwdat.mockdevice)
  implementation(libs.okhttp)
  testImplementation(libs.junit)
}
