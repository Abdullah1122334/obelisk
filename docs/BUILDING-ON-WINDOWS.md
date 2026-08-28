# Building Obelisk from Windows

You cannot build the ISO on Windows, and you are not supposed to. `mkarchiso` requires
an Arch Linux host, root privileges, and loop devices. Obelisk is designed around that
constraint rather than fighting it: **GitHub Actions is the build machine**, and your
Windows box is where you edit, review, and test.

Every command here is PowerShell unless marked otherwise.

## One-time setup

### 1. Git, configured so it cannot corrupt the project

This is the single most important step. Git on Windows defaults to rewriting line
endings, and a shell script that reaches Linux with CRLF fails with `bad interpreter`.

```powershell
winget install --id Git.Git -e

# Never rewrite line endings on checkout. .gitattributes pins everything to LF.
git config --global core.autocrlf false
git config --global core.eol lf
```

Verify:

```powershell
git config --get core.autocrlf   # must print: false
```

### 2. Your editor must write LF

VS Code:

```powershell
code --install-extension editorconfig.editorconfig
```

Then set `"files.eol": "\n"` in your user settings. If a file ever arrives with CRLF
despite `.gitattributes`, an editor wrote it that way after checkout.

### 3. Optional: QEMU, so you can boot the ISO locally

```powershell
winget install --id SoftwareFreedomConservancy.QEMU -e
```

Add QEMU to `PATH` for the current session:

```powershell
$env:PATH += ";C:\Program Files\qemu"
qemu-system-x86_64 --version
```

### 4. Optional: GitHub CLI, so you can drive CI from the terminal

```powershell
winget install --id GitHub.cli -e
gh auth login
```

## Clone

```powershell
git clone https://github.com/OWNER/obelisk.git
cd obelisk
```

Replace `OWNER` with the account in your `config.env`. Then confirm nothing arrived with
Windows line endings, using Git Bash (installed with Git):

```powershell
bash scripts/check-line-endings.sh
```

Expect `OK — N text files clean`. If it fails, your Git configuration rewrote something;
go back to step 1 and re-clone.

## Run a build

The build runs in CI. You trigger it and wait.

```powershell
git add -A
git commit -m "feat(iso): describe the change"
git push
```

Or trigger without a commit:

```powershell
gh workflow run build-iso.yml
```

Watch it:

```powershell
gh run watch
gh run list --workflow=build-iso.yml --limit 5
```

Read the logs of the most recent run:

```powershell
gh run view --log
```

## Download the built ISO

```powershell
# newest successful run
gh run download --name obelisk-iso --dir .\out

# a specific run
gh run list --workflow=build-iso.yml --limit 5
gh run download <RUN_ID> --name obelisk-iso --dir .\out
```

Verify the checksum before doing anything with it:

```powershell
$iso  = Get-ChildItem .\out\*.iso | Select-Object -First 1
$want = (Get-Content "$($iso.FullName).sha256").Split(' ')[0]
$got  = (Get-FileHash $iso.FullName -Algorithm SHA256).Hash.ToLower()
if ($got -eq $want) { "checksum OK" } else { "CHECKSUM MISMATCH - do not use this file" }
```

Build diagnostics — the profile manifest and the QEMU serial logs — are a separate
artifact:

```powershell
gh run download --name obelisk-build-diagnostics --dir .\out
```

## Test the ISO on Windows

### In QEMU

The test script is bash, so run it from Git Bash. It works on Windows as long as
`qemu-system-x86_64` is on `PATH`:

```powershell
bash scripts/test-qemu.sh --mode bios
```

UEFI mode needs an OVMF firmware image, which the QEMU for Windows package does not
always ship. Point at one explicitly if you have it:

```powershell
bash scripts/test-qemu.sh --mode uefi --ovmf "C:/Program Files/qemu/share/edk2-x86_64-code.fd"
```

If OVMF is unavailable locally, that is fine: CI runs both firmware modes on every push,
and CI is the authority for the acceptance criterion.

To watch the boot interactively rather than headlessly:

```powershell
qemu-system-x86_64 -machine q35 -m 4096 -smp 2 -cdrom .\out\obelisk.iso -boot d
```

### On real hardware

Write the ISO to a USB stick. Use Rufus in **DD mode** or Ventoy — do not use a tool
that unpacks the ISO onto a FAT partition, because that breaks the hybrid boot layout.

```powershell
winget install --id Rufus.Rufus -e
```

In Rufus: select the ISO, and when prompted choose **Write in DD Image mode**.

Ventoy is the better choice if you test often, because you can drop several ISOs on one
stick and it supports the persistence layout Obelisk targets in Phase 4.

## What you cannot do from Windows, and what to do instead

| You want to | Do this |
|---|---|
| Build the ISO | Push, or `gh workflow run build-iso.yml` |
| Build a package | Phase 2's `repo/build-packages.sh` runs in CI, same as the ISO |
| Run `shellcheck` | CI runs it on every push. Locally: `winget install koalaman.shellcheck` |
| Inspect the built root filesystem | Download the diagnostics artifact, or use an Arch VM |
| Iterate quickly on `airootfs` | An Arch VM is a genuine accelerator here — but never a requirement |

## Rules that exist because of Windows

These are not style preferences. Breaking any of them breaks the build in a way that is
expensive to diagnose:

1. **No backslash paths, drive letters, or `%USERPROFILE%` in any tracked file.**
   Everything inside the repository is POSIX. This document is the only place Windows
   paths appear, and it ships no code.
2. **Never rely on a file's executable bit from your checkout.** NTFS does not carry
   POSIX modes. Executable bits are declared in the `file_permissions` array in
   `iso/profiledef.sh` and in `install -Dm755` inside each PKGBUILD. When adding a new
   script to git, set the bit explicitly:

   ```powershell
   git update-index --chmod=+x scripts/your-script.sh
   ```
3. **Run `bash scripts/check-line-endings.sh` before you push.** It is the same check CI
   runs first, and catching it locally costs seconds instead of a full CI cycle.
