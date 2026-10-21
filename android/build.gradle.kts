import com.android.build.api.variant.LibraryAndroidComponentsExtension

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    // Older plugins hard-code SDK levels below their transitive AndroidX needs.
    // Keep library compilation aligned with the app's pinned Flutter SDK (36).
    plugins.withId("com.android.library") {
        extensions.getByType<LibraryAndroidComponentsExtension>().finalizeDsl { library ->
            library.compileSdk = maxOf(library.compileSdk ?: 36, 36)
        }
    }

    // Kotlin's incremental cache cannot relativize Windows paths across drives.
    // Hosted Flutter plugins can live on C: while the application lives on D:.
    if (System.getProperty("os.name").startsWith("Windows") &&
        projectDir.toPath().root != rootProject.projectDir.toPath().root
    ) {
        extensions.extraProperties["kotlin.incremental"] = "false"
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
