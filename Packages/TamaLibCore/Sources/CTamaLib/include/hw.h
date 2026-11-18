/*
 * TamaLIB - A hardware agnostic first-gen Tamagotchi emulation library
 *
 * Copyright (C) 2021 Jean-Christophe Rona <jc@rona.fr>
 *
 * This program is free software; you can redistribute it and/or
 * modify it under the terms of the GNU General Public License
 * as published by the Free Software Foundation; either version 2
 * of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 */
#ifndef _HW_H_
#define _HW_H_

#include "hal.h"

#define LCD_WIDTH			32
#define LCD_HEIGHT			16

#define ICON_NUM			8

typedef enum {
	BTN_STATE_RELEASED = 0,
	BTN_STATE_PRESSED,
} btn_state_t;

typedef enum {
	BTN_LEFT = 0,
	BTN_MIDDLE,
	BTN_RIGHT,
	BTN_TAP,
	/* iOS port: the K10-K13 input pins. Only the Yasashii has buttons
	 * there (toilet, affection, happiness, meal). */
	BTN_K10,
	BTN_K11,
	BTN_K12,
	BTN_K13,
} button_t;


bool_t hw_init(void);
void hw_release(void);

void hw_set_lcd_pin(u8_t seg, u8_t com, u8_t val);
void hw_set_button(button_t btn, btn_state_t state);

void hw_set_buzzer_freq(u4_t freq);
void hw_enable_buzzer(bool_t en);

/* iOS port: see hw.c. */
void hw_buzzer_shot(bool_t on);

#define HW_MODEL_P1                 0 /* P1, P2, Angel, Morino, Mothra: upstream wiring */
#define HW_MODEL_ICON_PER_SEGMENT   1 /* Umino, Genjintch, Tamaotch */
#define HW_MODEL_DIRECT             2 /* Yasashii */
#define HW_MODEL_DIGIMON            3 /* Digimon V1/V2/V3 */
void hw_set_model(u8_t model);

#endif /* _HW_H_ */
