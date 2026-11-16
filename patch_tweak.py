import sys

with open('Tweak.x', 'r') as f:
    code = f.read()

lines = code.split('\n')
result = []
i = 0
while i < len(lines):
    line = lines[i]
    if '__attribute__((constructor))' in line:
        new_ctor = '__attribute__((constructor))\nstatic void tweakConstructor() {\n    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{\n        [[AutoClickerManager sharedInstance] setupUI];\n    });\n}'
        result.append(new_ctor)
        brace_count = 0
        while i < len(lines):
            for ch in lines[i]:
                if ch == '{': brace_count += 1
                elif ch == '}': brace_count -= 1
            i += 1
            if brace_count == 0:
                break
        continue
    result.append(line)
    i += 1

with open('Tweak.x', 'w') as f:
    f.write('\n'.join(result))

print('Patched Tweak.x OK')
