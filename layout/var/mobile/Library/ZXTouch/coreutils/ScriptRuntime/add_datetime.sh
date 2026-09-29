#!/var/jb/bin/sh
OUTPUT=/var/mobile/Library/ZXTouch/coreutils/ScriptRuntime/output
DATE=/var/jb/usr/bin/date
if [ ! -x "$DATE" ]; then DATE=/usr/bin/date; fi
echo "$($DATE '+%m-%d-%Y %T'): 开始运行脚本，路径: $1" >> "$OUTPUT"
while IFS= read -r line; do
    echo "$($DATE '+%m-%d-%Y %T'): $line" >> "$OUTPUT"
done
