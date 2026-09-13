from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Any

from appdaemon.plugins.hass import Hass


@dataclass(frozen=True)
class LightSettings:
    on: bool
    brightness: int | None = None
    hs_color: tuple[float, float] | None = None
    rgb_color: tuple[int, int, int] | None = None
    color_temp_kelvin: int | None = None


@dataclass(frozen=True)
class Inputs:
    period: str
    present: bool
    mode: str
    override: LightSettings


def resolve(
    inputs: Inputs,
    period_settings: dict[str, LightSettings],
    default_settings: LightSettings,
) -> LightSettings:
    """
    Pure lighting policy.

    Precedence:
      1. Force off
      2. Force on
      3. Custom override light
      4. Automatic + presence
      5. Automatic scheduled period
    """

    if inputs.mode == "Force off":
        return LightSettings(on=False)

    if inputs.mode == "Force on":
        return LightSettings(
            on=True,
            brightness=255,
            hs_color=default_settings.hs_color,
            rgb_color=default_settings.rgb_color,
            color_temp_kelvin=default_settings.color_temp_kelvin,
        )

    if inputs.override.on:
        return inputs.override

    if inputs.mode != "Automatic":
        raise ValueError(f"Unknown light mode: {inputs.mode!r}")

    # Presence only gates normal automatic lighting.
    if not inputs.present:
        return LightSettings(on=False)

    try:
        period = period_settings[inputs.period]
    except KeyError:
        raise ValueError(f"Unknown light period: {inputs.period!r}")

    if not period.on:
        return LightSettings(on=False)

    return LightSettings(
        on=True,
        brightness=period.brightness,
        hs_color=default_settings.hs_color,
        rgb_color=default_settings.rgb_color,
        color_temp_kelvin=default_settings.color_temp_kelvin,
    )


class LightController(Hass):
    def initialize(self):
        self.label = self.args["label"]

        self.period_entity = self.args.get(
            "period_entity",
            "input_select.light_period",
        )
        self.presence_entity = self.args.get(
            "presence_entity",
            "binary_sensor.physical_presence",
        )
        self.mode_entity = self.args.get(
            "mode_entity",
            "input_select.light_state",
        )
        self.override_entity = self.args.get(
            "override_entity",
            "light.light_override",
        )

        self.transition = float(self.args.get("transition", 5))

        self.default_settings = self.parse_settings(
            self.args.get("default_settings", {})
        )

        self.period_settings = {
            period: self.parse_settings(settings)
            for period, settings in self.args["period_settings"].items()
        }

        self.reconcile_timer = None
        self.ignore_target_changes_until = 0.0

        self.log(
            "Initialized: "
            f"label={self.label!r}, "
            f"period={self.period_entity}, "
            f"presence={self.presence_entity}, "
            f"mode={self.mode_entity}, "
            f"override={self.override_entity}"
        )

        # Every input change has exactly the same behavior:
        # recompute desired state from scratch.
        self.listen_state(
            self.on_input_change,
            self.period_entity,
        )
        self.listen_state(
            self.on_input_change,
            self.presence_entity,
        )
        self.listen_state(
            self.on_input_change,
            self.mode_entity,
        )

        # Brightness/color changes are attribute changes.
        self.listen_state(
            self.on_input_change,
            self.override_entity,
            attribute="all",
        )

        self.watch_targets()
        self.reconcile("initialization")

    # ------------------------------------------------------------------
    # Inputs
    # ------------------------------------------------------------------

    def on_input_change(
        self,
        entity,
        attribute,
        old,
        new,
        kwargs,
    ):
        self.schedule_reconcile(
            0.1,
            f"{entity} changed",
        )

    def schedule_reconcile(
        self,
        delay: float,
        reason: str,
    ):
        if self.reconcile_timer is not None:
            self.cancel_timer(self.reconcile_timer)

        self.reconcile_timer = self.run_in(
            self.run_reconcile,
            delay,
            reason=reason,
        )

    def run_reconcile(self, kwargs):
        self.reconcile_timer = None
        self.reconcile(kwargs["reason"])

    def inputs(self) -> Inputs:
        return Inputs(
            period=self.get_state(
                self.period_entity,
            ),
            present=(
                self.get_state(
                    self.presence_entity,
                )
                == "on"
            ),
            mode=self.get_state(
                self.mode_entity,
            ),
            override=self.override_settings(),
        )

    # ------------------------------------------------------------------
    # Reconciliation
    # ------------------------------------------------------------------

    def reconcile(self, reason: str):
        lights, switches = self.targets()

        if not lights and not switches:
            self.log(
                f"No lights/switches have label {self.label!r}",
                level="WARNING",
            )
            return

        inputs = self.inputs()

        try:
            desired = resolve(
                inputs,
                self.period_settings,
                self.default_settings,
            )
        except ValueError as error:
            self.log(
                str(error),
                level="WARNING",
            )
            return

        self.log(
            f"Reconciling ({reason}): "
            f"period={inputs.period!r}, "
            f"present={inputs.present}, "
            f"mode={inputs.mode!r}, "
            f"override={inputs.override.on}, "
            f"desired={desired}"
        )

        self.apply_desired(
            lights,
            switches,
            desired,
        )

    def apply_desired(
        self,
        lights: list[str],
        switches: list[str],
        desired: LightSettings,
    ):
        # Prevent our own transition updates from immediately causing
        # another reconciliation.
        self.ignore_target_changes_until = (
            time.monotonic()
            + self.transition
            + 0.5
        )

        if not desired.on:
            if lights:
                self.call_service(
                    "light/turn_off",
                    entity_id=lights,
                    transition=self.transition,
                )

            self.set_switches(
                switches,
                False,
            )
            return

        payload: dict[str, Any] = {
            "entity_id": lights,
            "transition": self.transition,
        }

        if desired.brightness is not None:
            payload["brightness"] = desired.brightness

        if desired.hs_color is not None:
            payload["hs_color"] = desired.hs_color

        if desired.rgb_color is not None:
            payload["rgb_color"] = desired.rgb_color

        if desired.color_temp_kelvin is not None:
            payload["color_temp_kelvin"] = (
                desired.color_temp_kelvin
            )

        if lights:
            self.call_service(
                "light/turn_on",
                **payload,
            )

        # Approximate dimmable state for binary-only targets.
        switch_on = (
            desired.brightness is None
            or desired.brightness > 128
        )

        self.set_switches(
            switches,
            switch_on,
        )

    # ------------------------------------------------------------------
    # Override
    # ------------------------------------------------------------------

    def override_settings(self) -> LightSettings:
        value = self.get_state(
            self.override_entity,
            attribute="all",
        )

        if not value or value.get("state") != "on":
            return LightSettings(on=False)

        attributes = value.get(
            "attributes",
            {},
        )

        brightness = attributes.get("brightness")

        hs_color = None
        rgb_color = None
        color_temp_kelvin = None

        color_mode = attributes.get(
            "color_mode"
        )

        if color_mode == "hs":
            value = attributes.get(
                "hs_color"
            )

            if value:
                hs_color = tuple(value)

        elif color_mode == "rgb":
            value = attributes.get(
                "rgb_color"
            )

            if value:
                rgb_color = tuple(value)

        elif color_mode == "color_temp":
            color_temp_kelvin = (
                attributes.get(
                    "color_temp_kelvin"
                )
            )

        return LightSettings(
            on=True,
            brightness=brightness,
            hs_color=hs_color,
            rgb_color=rgb_color,
            color_temp_kelvin=color_temp_kelvin,
        )

    # ------------------------------------------------------------------
    # Config parsing
    # ------------------------------------------------------------------

    def parse_settings(
        self,
        raw: dict[str, Any],
    ) -> LightSettings:
        if not raw.get("enabled", True):
            return LightSettings(
                on=False,
            )

        brightness = raw.get(
            "brightness"
        )

        if (
            brightness is None
            and "brightness_pct" in raw
        ):
            brightness = round(
                float(
                    raw["brightness_pct"]
                )
                / 100
                * 255
            )

        return LightSettings(
            on=True,
            brightness=brightness,
            hs_color=(
                tuple(raw["hs_color"])
                if "hs_color" in raw
                else None
            ),
            rgb_color=(
                tuple(raw["rgb_color"])
                if "rgb_color" in raw
                else None
            ),
            color_temp_kelvin=raw.get(
                "color_temp_kelvin"
            ),
        )

    # ------------------------------------------------------------------
    # Physical targets
    # ------------------------------------------------------------------

    def targets(self):
        entities = (
            set(
                self.label_entities(
                    self.label
                )
            )
            - {self.override_entity}
        )

        lights = []
        switches = []

        for entity in sorted(entities):
            if entity.startswith("switch."):
                switches.append(entity)
                continue

            if not entity.startswith("light."):
                continue

            color_modes = (
                self.get_state(
                    entity,
                    attribute="supported_color_modes",
                )
                or []
            )

            if set(color_modes) == {"onoff"}:
                switches.append(entity)
            else:
                lights.append(entity)

        return lights, switches

    def watch_targets(self):
        lights, switches = self.targets()

        for entity in lights + switches:
            self.listen_state(
                self.on_target_change,
                entity,
                attribute="all",
            )

        self.log(
            f"Watching targets: {lights + switches}"
        )

    def on_target_change(
        self,
        entity,
        attribute,
        old,
        new,
        kwargs,
    ):
        if (
            time.monotonic()
            < self.ignore_target_changes_until
        ):
            return

        self.schedule_reconcile(
            0.25,
            f"{entity} drifted",
        )

    def set_switches(
        self,
        entities: list[str],
        on: bool,
    ):
        light_entities = [
            entity
            for entity in entities
            if entity.startswith("light.")
        ]

        switch_entities = [
            entity
            for entity in entities
            if entity.startswith("switch.")
        ]

        if light_entities:
            self.call_service(
                (
                    "light/turn_on"
                    if on
                    else "light/turn_off"
                ),
                entity_id=light_entities,
            )

        if switch_entities:
            self.call_service(
                (
                    "switch/turn_on"
                    if on
                    else "switch/turn_off"
                ),
                entity_id=switch_entities,
            )
