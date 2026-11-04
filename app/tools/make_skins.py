#!/usr/bin/env python3
"""Writes the skin dictionaries app/src/ZynqForth/Themes/<Skin>.xaml from one table, so every
skin defines the same keys. Run after changing a colour: python app/tools/make_skins.py"""

import os

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'src', 'ZynqForth', 'Themes')

# key: (description, IDE dark, IDE light, Green phosphor, Amber, Lab panel)
BRUSHES = [
    ('Window',             'window background',        '#1E1E1E', '#F3F3F3', '#020802', '#0A0600', 'grad:#3A4048:#262A30'),
    ('Panel',              'panel background',         '#252526', '#FFFFFF', '#041004', '#120C02', '#30353C'),
    ('PanelHeader',        'panel heading text',       '#9DA5B4', '#5A6270', '#2AD155', '#D99600', '#E8ECF0'),
    ('Border',             'panel and control borders', '#3C3C3C', '#D6D6D6', '#1A5C2A', '#5C4000', '#15181C'),
    ('Text',               'normal text',              '#D4D4D4', '#1F1F1F', '#33FF66', '#FFB000', '#E8ECF0'),
    ('DimText',            'secondary text',           '#8B8F98', '#6A6F78', '#1C9E40', '#A87400', '#9AA3AD'),
    ('Accent',             'selected / on',            '#3794FF', '#005FB8', '#33FF66', '#FFB000', '#FF8A00'),
    ('AccentText',         'text on the accent',       '#FFFFFF', '#FFFFFF', '#021002', '#140C00', '#1A1A1A'),
    ('Error',              'errors',                   '#F48771', '#C42B1C', '#FF5050', '#FF5030', '#FF5A4A'),
    ('Warning',            'warnings',                 '#CCA700', '#9A6700', '#C8FF66', '#FFE070', '#FFD24A'),
    ('ButtonBackground',   'button face',              '#333337', '#FBFBFB', '#062A0E', '#2A1C00', 'grad:#5A626C:#40464E'),
    ('ButtonBorder',       'button border',            '#45454A', '#C8C8C8', '#1F8A3C', '#8A6000', '#16191D'),
    ('ButtonHover',        'button face, hovered',     '#3E3E42', '#EFEFEF', '#0C4A1C', '#4A3200', 'grad:#6A737E:#4C535C'),
    ('ButtonPressed',      'button face, pressed',     '#094771', '#D9E7F5', '#1F8A3C', '#8A6000', '#2A2F35'),
    ('ButtonText',         'button text',              '#E0E0E0', '#1F1F1F', '#33FF66', '#FFB000', '#F2F4F6'),
    ('InputBackground',    'text boxes and lists',     '#1E1E1E', '#FFFFFF', '#020802', '#0A0600', '#1D2126'),
    ('InputText',          'text in boxes and lists',  '#D4D4D4', '#1F1F1F', '#33FF66', '#FFB000', '#E8ECF0'),
    ('Selection',          'selected list item',       '#264F78', '#CCE4F7', '#0E5A22', '#5A3E00', '#7A4A10'),
    ('TerminalBackground', 'terminal',                 '#181818', '#FFFFFF', '#010601', '#080500', '#B9C7A2'),
    ('TerminalText',       'terminal text',            '#CCCCCC', '#1F1F1F', '#40FF70', '#FFB52E', '#1B2414'),
    ('EditorBackground',   'editor',                   '#1E1E1E', '#FFFFFF', '#020802', '#0A0600', '#1D2126'),
    ('EditorText',         'editor text',              '#D4D4D4', '#1F1F1F', '#33FF66', '#FFB000', '#E8ECF0'),
    ('Caret',              'text caret',               '#AEAFAD', '#000000', '#66FF8C', '#FFC840', '#FF8A00'),
    ('BoardBackground',    'board view background',    '#1E1E1E', '#F3F3F3', '#020802', '#0A0600', 'grad:#3A4048:#262A30'),
    ('BoardPcb',           'the board itself',         '#1F3B2B', '#2D5A3F', '#031A08', '#1A1000', '#20262C'),
    ('BoardText',          'silkscreen text',          '#E6E6E6', '#F2F2F2', '#33FF66', '#FFB000', '#E8ECF0'),
    ('LedOn',              'LD0..LD3 lit',             '#4CFF6A', '#3BE85A', '#66FF8C', '#FFD060', '#7CFF4A'),
    ('LedOff',             'LED dark',                 '#2A332C', '#3C4A40', '#0A2410', '#241800', '#1A1E22'),
    ('PinHigh',            'input pin reading 1',      '#7FB8FF', '#9CC8FF', '#33FF66', '#FFB000', '#7FC4FF'),
    ('PinLow',             'input pin reading 0',      '#3A3F46', '#55606C', '#0A2A12', '#2A1C00', '#2A3036'),
    ('PinDriven',          'output pin driving 1',     '#FF6B4A', '#FF6B4A', '#C8FF66', '#FFE070', '#FF8A00'),
    ('PinDrivenLow',       'output pin driving 0',     '#7A2E20', '#8A3A2A', '#2A5A10', '#5A3E00', '#6A3A0A'),
    ('PinPwm',             'pin owned by PWM',         '#C586C0', '#B05CC0', '#9CFFB4', '#FFD890', '#E05AE0'),
    ('ButtonCap',          'push button cap',          '#5A5F66', '#6C737C', '#0C3A18', '#3A2800', '#4A5058'),
    ('ButtonCapPressed',   'push button pressed',      '#3794FF', '#3794FF', '#33FF66', '#FFB000', '#FF8A00'),
]

FONTS = [
    # key, IDE dark, IDE light, Green phosphor, Amber, Lab panel
    ('UiFont',   'Segoe UI', 'Segoe UI', 'Consolas', 'Consolas', 'Bahnschrift'),
    ('CodeFont', 'Cascadia Mono, Consolas', 'Cascadia Mono, Consolas', 'Consolas', 'Consolas', 'Consolas'),
]
SIZES = [
    ('UiSize',   12, 12, 13, 13, 12),
    ('CodeSize', 13, 13, 15, 15, 14),
    ('Radius',   2, 4, 0, 0, 3),
]
GLOW = [None, None, '#33FF66', '#FFB000', None]

SKINS = [('IdeDark', 'IDE dark: a dark editor look, one blue accent.'),
         ('IdeLight', 'IDE light: the light editor look.'),
         ('GreenPhosphor', 'Green phosphor: a P1 CRT terminal, glowing text on black.'),
         ('Amber', 'Amber: a P3 CRT terminal, glowing amber on black.'),
         ('LabPanel', 'Lab panel: an instrument front panel with an LCD terminal; shows the board.')]


def brush(key, value):
    if value.startswith('grad:'):
        top, bottom = value[5:].split(':')
        return (f'    <LinearGradientBrush x:Key="Zf.{key}" StartPoint="0,0" EndPoint="0,1">\n'
                f'        <GradientStop Offset="0" Color="{top}" />\n'
                f'        <GradientStop Offset="1" Color="{bottom}" />\n'
                f'    </LinearGradientBrush>\n')
    return f'    <SolidColorBrush x:Key="Zf.{key}" Color="{value}" />\n'


def main():
    for i, (name, about) in enumerate(SKINS):
        out = ['<!-- Generated by app/tools/make_skins.py; edit the table there. -->\n',
               '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"\n',
               '                    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"\n',
               '                    xmlns:sys="clr-namespace:System;assembly=System.Runtime">\n\n',
               f'    <!-- {about} -->\n\n']
        for key, description, *values in BRUSHES:
            out.append(f'    <!-- {description} -->\n')
            out.append(brush(key, values[i]))
        out.append('\n')
        for key, *values in FONTS:
            out.append(f'    <FontFamily x:Key="Zf.{key}">{values[i]}</FontFamily>\n')
        for key, *values in SIZES:
            if key == 'Radius':
                out.append(f'    <CornerRadius x:Key="Zf.{key}">{values[i]}</CornerRadius>\n')
            else:
                out.append(f'    <sys:Double x:Key="Zf.{key}">{values[i]}</sys:Double>\n')
        out.append('\n    <!-- glow on terminal and editor text (retro skins), else none -->\n')
        if GLOW[i]:
            out.append(f'    <DropShadowEffect x:Key="Zf.TextGlow" Color="{GLOW[i]}" BlurRadius="7" '
                       'ShadowDepth="0" Opacity="0.75" />\n')
        else:
            out.append('    <x:Null x:Key="Zf.TextGlow" />\n')
        out.append('\n</ResourceDictionary>\n')
        with open(os.path.join(OUT, name + '.xaml'), 'w', newline='\r\n', encoding='utf-8') as f:
            f.writelines(out)
        print('wrote', name + '.xaml')


if __name__ == '__main__':
    main()
