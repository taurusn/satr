---
linen:
  eyebrow: الجاهزية · أكتوبر
  lead: أين تقف خدمة الطلبات، صندوقًا صندوقًا، مع الدليل وراء كل حالة.
  words:
    - {word: يعمل, shape: outline, quiet: true}
    - {word: جزئي, shape: threads}
    - {word: معطل, shape: rust, meaning: يفشل عند الاستخدام}
    - {word: غير موجود, shape: dashed}
    - {word: مخطط, shape: dotted}
---
# خدمة الطلبات: أين تقف

تأخذ الخدمة الطلب من النموذج إلى قائمة المعتمد. لا تستطيع تسجيل القرار بعد[^1]، فلا يصل شيء إلى الفوترة.

```tiles
cols: 4
items:
  - {label: صندوقًا على الخريطة, value: "١٧٠"}
  - {label: تعمل من أولها لآخرها, value: "٧٦", word: يعمل}
  - {label: معطل, value: "١٠", word: معطل}
  - {label: غير موجود, value: "١٤", word: غير موجود}
```

```bar
items:
  - {word: يعمل, count: 76}
  - {word: جزئي, count: 52}
  - {word: معطل, count: 10}
  - {word: غير موجود, count: 14}
  - {word: مخطط, count: 18}
```

```steps
kind: steps
items: [مسودة, مراجعة, اعتماد, نشر]
current: 3
```

```cards
cols: 2
items:
  - {eyebrow: الخطوة ١, title: الاستلام, body: "يتحقق من **الطلب** ويحفظه.", word: يعمل}
  - {eyebrow: التالي, title: الاعتماد, body: "المحور الذي ينتظره كل شيء.", tone: ink}
```

| الصندوق | الحالة |
|---|---|
| نموذج الطلب {#مرحلة} | :w[يعمل] |
| مسار الاعتماد | :w[معطل] |

[^1]: الاعتماد والإرجاع يجيبان كلاهما بـ 403. المصدر: `server/approvals.py:118`.
