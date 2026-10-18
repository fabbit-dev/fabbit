# Проверка: главная плата

На плате пока механика: контур, отверстия и заглушки `MECH_*`. Схемы нет. Компоненты по
даташитам сверим вместе со схемой, тогда здесь появится таблица: MPN, LCSC, даташит, пины,
футпринт, режимы.

## Механика

Источник: `mech/fabbit_mainboard_placement.csv` и `mech/README.md`. Координаты платы:
x = X + 100, y = 200 + y из CSV. Допуск сверки 0,05 мм: центр и размер рамки Fab
(у отверстий центр и диаметр сверла) против строки CSV.

- Контур 84,4 × 145,6 мм, x 57,8…142,2, y 52,2…197,8: 16 отрезков. Вырезы USB-C 9,24 × 5,8,
  HDMI 15,4 × 7,9, под антенной ESP32-C5 6,5 × 25,5. Отверстие динамика Ø20,6, порт микрофона Ø0,9.
- Толщина 1,5 мм.
- 52 футпринта на 61 строку CSV. Строка `ESP_Keepout` задаёт вырез в контуре.

| Обозн. | Футпринт | Строки CSV | Сторона | Статус | Дата |
|---|---|---|---|---|---|
| H1…H8 | MountingHole:MountingHole_2.2mm_M2 | H1…H8 | NPTH Ø2,2 | ok | 2026-10-18 |
| H9…H12 | Mounting_Wuerth:Mounting_Wuerth_WA-SMSI-M2.5_H9mm_9774090151 | H9…H12, Mezz_Standoff_0…3 | B, отверстие Ø3,7 | ? | 2026-10-18 |
| SCR1 | MECH_Screen_70x51 | Screen | F | ok | 2026-10-18 |
| SW1…SW11 | MECH_SW_4x4 | SW_Up, SW_Down, SW_Left, SW_Right, SW_F1, SW_F3, SW_F4, SW_F2, SW_Fn, SW_Menu, SW_Back | F | ok | 2026-10-18 |
| SW12 | MECH_SW_SKRTLAE010 | Power | B | ok | 2026-10-18 |
| SW13 | MECH_SW_3x4 | Recovery_SW | F | ok | 2026-10-18 |
| J1 | MECH_BergStak_2x40_9mm | B2B_80p | B | ok | 2026-10-18 |
| J2 | MECH_microSD_DM3AT | microSD | B | ok | 2026-10-18 |
| J3 | MECH_USB_C_HCTL_24P | USB_C | B | ok | 2026-10-18 |
| J4 | MECH_HDMI_A_HDGC_GD116 | HDMI_A | в вырезе | ok | 2026-10-18 |
| J5 | MECH_Socket_DS1024_2x12_RA | Header_A | B | ok | 2026-10-18 |
| J6 | MECH_Socket_DS1024_2x2_RA | Header_PWR | B | ok | 2026-10-18 |
| J7 | MECH_Socket_DS1024_2x10_RA | Header_B | B | ok | 2026-10-18 |
| J8 | MECH_FPC54_BXCONN | FPC_Screen | F | ok | 2026-10-18 |
| J9 | MECH_MIPI20_FTSH_110_RA | MIPI20 | B | ok | 2026-10-18 |
| U1 | MECH_CH32H417_QFN128 | CH32H417 | F | ok | 2026-10-18 |
| U2 | MECH_ESP32C5_MINI1 | ESP32_C5 | B, антенна к X+ | ok | 2026-10-18 |
| MOD1 | MECH_SODIMM_TE1473005_i9plus | SODIMM_Socket, i9_Module | B, начало (100; 140) | ok | 2026-10-18 |
| HS1 | MECH_Heat_Spreader_23x22 | Heat_Spreader | B | ok | 2026-10-18 |
| ENC1 | MECH_Encoder_SIQ02 | Wheel, Encoder | B, начало на оси колеса | ? | 2026-10-18 |
| LS1 | MECH_Speaker_D20 | Speaker | в вырезе | ok | 2026-10-18 |
| MK1 | MECH_Mic_SPH0641 | Mic | B | ok | 2026-10-18 |
| M1 | MECH_LRA_12x3.4 | LRA | B | ok | 2026-10-18 |
| BT1 | MECH_Battery_70x40 | Battery | B | ok | 2026-10-18 |
| A1 | MECH_Area_F_Power_27.4x17 | Z_F_Power | F | ok | 2026-10-18 |
| A2 | MECH_Area_F_MCU_25x16 | Z_F_MCU | F | ok | 2026-10-18 |
| A3 | MECH_Area_B_Low_68x23.7 | Z_B_Low | B | ok | 2026-10-18 |
| A4 | MECH_Area_B_Scoop_25x10.6 | Z_B_Scoop | B | ok | 2026-10-18 |
| A5 | MECH_Area_B_LabPSU_28x13.5 | Z_B_LabPSU | B | ok | 2026-10-18 |
| A6 | MECH_Area_B_Anlz_A_21.5x13.4 | Z_B_Anlz_A | B | ok | 2026-10-18 |
| A7 | MECH_Area_B_Anlz_B_22x7.6 | Z_B_Anlz_B | B | ok | 2026-10-18 |
| A8 | MECH_Battery_Tail_5x18 | Battery_Tail | B | ok | 2026-10-18 |

## DRC

- DRC: 0 ошибок, неразведено 0 (kicad-cli 10.0.6, 2026-10-18).
- Предупреждения: 2, шёлк обозначений заглушек. J3 у края платы, A2 и U1 в одной точке.
  Заглушки уйдут с платы до заказа.

## Исключения ERC/DRC

Правила в `fabbit_mainboard.kicad_dru`:

- `hole_clearance` 0 мм внутри H9…H12: площадка Würth WA-SMSI касается отверстия Ø3,7
  своего же футпринта, так рекомендует Würth.
- `courtyard_clearance` −0,01 мм между H9…H12 и SCR1 снимает `npth_inside_courtyard`.
  Отверстия стоек лежат под экраном, H9 и H10 заходят под него на 0,55 мм. Экран стоит
  модулем перед F, на F под ним ничего нет, стойка и винт сидят на B.

## Открытые вопросы

- H9…H12: корпус стойки Ø5,1 по футпринту KiCad, в CSV механики Ø5,0. Сверить по даташиту
  Würth 9774090151 и поправить модель корпуса или CSV.
- ENC1: корпус энкодера 10,3 мм выходит за край платы на 1,25 мм, в CSV он обрезан краем
  (9,05 мм, метка «?»). Сверить по чертежу Mitsumi SIQ-02FVS3.
- Направляющие кнопки SKRTLAE010 (Ø0,9) и NPTH Ø1,02 разъёма MIPI20 в контур не входят:
  их дадут настоящие футпринты со схемой.
