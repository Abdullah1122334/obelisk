# بناء أوبيليسك من ويندوز

لا تستطيع بناء صورة الـ ISO على ويندوز، وليس مفترضًا بك ذلك. فـ `mkarchiso` يتطلب مضيف آرتش
لينكس وصلاحية الجذر وأجهزة loop. وقد صُمِّم أوبيليسك حول هذا القيد بدل مصارعته:
**GitHub Actions هو آلة البناء**، وجهازك على ويندوز هو مكان التحرير والمراجعة والاختبار.

كل الأوامر هنا بلغة PowerShell ما لم يُذكر غير ذلك.

## إعداد لمرة واحدة

### ١. جِت، مضبوطًا بحيث لا يُفسِد المشروع

هذه أهم خطوة على الإطلاق. فـ Git على ويندوز يُعيد كتابة نهايات الأسطر افتراضيًّا، وسكربت
صدفة يصل إلى لينكس بنهايات CRLF يفشل برسالة `bad interpreter`.

```powershell
winget install --id Git.Git -e

# لا تُعِد كتابة نهايات الأسطر عند السحب أبدًا. ملف .gitattributes يُثبِّت كل شيء على LF.
git config --global core.autocrlf false
git config --global core.eol lf
```

للتأكد:

```powershell
git config --get core.autocrlf   # يجب أن يطبع: false
```

### ٢. يجب أن يكتب محررك بنهايات LF

في VS Code:

```powershell
code --install-extension editorconfig.editorconfig
```

ثم اضبط `"files.eol": "\n"` في إعدادات المستخدم. وإن وصل ملف بنهايات CRLF رغم
`.gitattributes`، فذلك يعني أن محررًا كتبه هكذا بعد السحب.

### ٣. اختياري: QEMU لتُقلِع الصورة محليًّا

```powershell
winget install --id SoftwareFreedomConservancy.QEMU -e
$env:PATH += ";C:\Program Files\qemu"
qemu-system-x86_64 --version
```

### ٤. اختياري: واجهة GitHub لسطر الأوامر

```powershell
winget install --id GitHub.cli -e
gh auth login
```

## الاستنساخ

```powershell
git clone https://github.com/OWNER/obelisk.git
cd obelisk
```

استبدل `OWNER` بالحساب المذكور في `config.env` عندك. ثم تأكّد أن شيئًا لم يصل بنهايات أسطر
ويندوز، من داخل Git Bash المُثبَّت مع Git:

```powershell
bash scripts/check-line-endings.sh
```

المتوقع `OK — N text files clean`. وإن فشل، فإعداد Git عندك أعاد كتابة شيء: ارجع للخطوة
الأولى وأعد الاستنساخ.

## تشغيل بناء

البناء يجري في CI. أنت تُطلِقه وتنتظر.

```powershell
git add -A
git commit -m "feat(iso): describe the change"
git push
```

أو أطلِقه دون إيداع:

```powershell
gh workflow run build-iso.yml
gh run watch
gh run list --workflow=build-iso.yml --limit 5
gh run view --log
```

## تنزيل الصورة المبنية

```powershell
gh run download --name obelisk-iso --dir .\out
```

تحقّق من البصمة قبل أي استخدام:

```powershell
$iso  = Get-ChildItem .\out\*.iso | Select-Object -First 1
$want = (Get-Content "$($iso.FullName).sha256").Split(' ')[0]
$got  = (Get-FileHash $iso.FullName -Algorithm SHA256).Hash.ToLower()
if ($got -eq $want) { "checksum OK" } else { "CHECKSUM MISMATCH - do not use this file" }
```

وتشخيصات البناء — بيان الملف الشخصي وسجلات QEMU التسلسلية — ناتج منفصل:

```powershell
gh run download --name obelisk-build-diagnostics --dir .\out
```

## اختبار الصورة على ويندوز

### في QEMU

سكربت الاختبار مكتوب بلغة bash، فشغّله من Git Bash. وهو يعمل على ويندوز ما دام
`qemu-system-x86_64` في المسار:

```powershell
bash scripts/test-qemu.sh --mode bios
bash scripts/test-qemu.sh --mode uefi --ovmf "C:/Program Files/qemu/share/edk2-x86_64-code.fd"
```

ونمط UEFI يحتاج صورة برنامج ثابت OVMF لا تشحنها حزمة QEMU لويندوز دائمًا. وإن لم تتوفر
محليًّا فلا بأس: يُشغّل CI النمطين في كل دفعة، وهو المرجع في معيار القبول.

ولمشاهدة الإقلاع تفاعليًّا بدل بلا شاشة:

```powershell
qemu-system-x86_64 -machine q35 -m 4096 -smp 2 -cdrom .\out\obelisk.iso -boot d
```

### على عتاد حقيقي

اكتب الصورة على ذاكرة USB باستخدام Rufus في **وضع DD** أو باستخدام Ventoy. ولا تستخدم أداة
تفكّ الصورة إلى قسم FAT، لأن ذلك يكسر تخطيط الإقلاع الهجين.

```powershell
winget install --id Rufus.Rufus -e
```

في Rufus: اختر الصورة، وعند السؤال اختر **الكتابة بوضع DD Image**.

و Ventoy خيار أفضل إن كنت تختبر كثيرًا، لأنك تضع عدة صور على ذاكرة واحدة، وهو يدعم تخطيط
الاستمرارية الذي يستهدفه أوبيليسك في المرحلة الرابعة.

## ما لا تستطيعه من ويندوز، وما تفعله بدلًا منه

| تريد أن | افعل هذا |
|---|---|
| تبني الصورة | ادفع، أو `gh workflow run build-iso.yml` |
| تبني حزمة | `repo/build-packages.sh` في المرحلة الثانية يعمل في CI كالصورة تمامًا |
| تُشغّل `shellcheck` | يُشغّله CI في كل دفعة، مثبَّتًا على **shellcheck v0.11.0** حتى تتطابق النتيجة محليًّا وفي CI. استخدم الإصدار نفسه والأعلام نفسها من Git Bash في جذر المستودع: `shellcheck -x -P "$(git rev-parse --show-toplevel)" --severity=warning $(git ls-files "*.sh")` |
| تفحص نظام الملفات المبني | نزّل ناتج التشخيصات، أو استخدم آلة آرتش افتراضية |
| تُكرِّر بسرعة على `airootfs` | آلة آرتش افتراضية مُسرِّع حقيقي هنا — لكنها ليست شرطًا أبدًا |

## قواعد موجودة بسبب ويندوز

هذه ليست تفضيلات أسلوبية. وكسر أي منها يكسر البناء بطريقة مكلفة التشخيص:

1. **لا مسارات بشرطة عكسية، ولا أحرف أقراص، ولا `%USERPROFILE%` في أي ملف مُتتبَّع.** كل ما
   داخل المستودع POSIX. وهذا الملف هو الموضع الوحيد الذي تظهر فيه مسارات ويندوز، وهو لا
   يشحن شيفرة.
2. **لا تعتمد أبدًا على بت التنفيذ من نسختك المحلية.** فـ NTFS لا يحمل صلاحيات POSIX. وبتات
   التنفيذ مُعلَنة في مصفوفة `file_permissions` في `iso/profiledef.sh` وفي `install -Dm755`
   داخل كل PKGBUILD. وعند إضافة سكربت جديد إلى Git، اضبط البت صراحةً:

   ```powershell
   git update-index --chmod=+x scripts/your-script.sh
   ```
3. **شغّل `bash scripts/check-line-endings.sh` قبل الدفع.** هو الفحص نفسه الذي يُشغّله CI
   أولًا، والتقاطه محليًّا يكلّف ثوانٍ بدل دورة CI كاملة.
