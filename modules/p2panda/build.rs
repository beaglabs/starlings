use std::env;
use std::path::PathBuf;
use std::process::Command;

fn main() {
    let manifest_dir = PathBuf::from(
        env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"),
    );
    let zig_source = manifest_dir.join("zig/stage7c_policy_ffi.zig");
    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR"));
    let output = out_dir.join("starlings_stage7c.o");
    let zig = env::var("ZIG").unwrap_or_else(|_| "zig".to_string());

    for path in [
        "zig/stage7c_policy_ffi.zig",
        "zig/stage7a_policy.zig",
        "zig/stage5a_scaling.zig",
    ] {
        println!("cargo:rerun-if-changed={}", manifest_dir.join(path).display());
    }

    let status = Command::new(&zig)
        .arg("build-obj")
        .arg(&zig_source)
        .arg("-O")
        .arg("ReleaseFast")
        .arg("-fPIC")
        .arg(format!("-femit-bin={}", output.display()))
        .status()
        .unwrap_or_else(|err| panic!("failed to invoke {zig}: {err}"));

    if !status.success() {
        panic!("Zig Stage 7C policy object build failed: {status}");
    }

    println!("cargo:rustc-link-arg={}", output.display());
}
