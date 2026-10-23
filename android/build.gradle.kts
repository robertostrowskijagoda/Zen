allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

// flutter_webrtc adds JitPack (https://jitpack.io) to every project for one
// library built from a GitHub commit (com.github.davidliu:audioswitch).
// JitPack builds whatever a repository holds, so here it serves that one
// group only: everything else comes from Google's repository and Maven
// Central, where a published file cannot be replaced.
allprojects {
    repositories.withType<MavenArtifactRepository>().configureEach {
        if (url.host == "jitpack.io") {
            content { includeGroup("com.github.davidliu") }
        }
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
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
