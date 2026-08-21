/** @odoo-module **/

import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { Component, onWillStart, useState } from "@odoo/owl";

/**
 * Renders a vertikali.view image with its polygons drawn on top as clickable
 * SVG regions.
 *
 * Points are stored normalized (0..1), so the SVG uses a 0..1 viewBox with
 * preserveAspectRatio="none": the overlay then stretches with the image
 * regardless of its pixel size or aspect ratio.
 */
export class VertikaliSelector extends Component {
    static template = "vertikali.Selector";
    static props = { ...Component.props, action: { type: Object, optional: true } };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.state = useState({
            views: [],
            view: null,
            zones: [],
            hovered: null,
            selected: null,
            loading: true,
            error: null,
        });

        onWillStart(async () => {
            try {
                const views = await this.orm.searchRead(
                    "vertikali.view", [], ["name", "view_type", "building", "floor"],
                    { order: "view_type, sequence, id" }
                );
                this.state.views = views;
                if (views.length) {
                    await this.loadView(views[0].id);
                }
            } catch (e) {
                this.state.error = e.message || String(e);
            } finally {
                this.state.loading = false;
            }
        });
    }

    async loadView(viewId) {
        this.state.loading = true;
        this.state.selected = null;
        try {
            const [view] = await this.orm.read(
                "vertikali.view", [viewId],
                ["name", "view_type", "building", "floor", "image"]
            );
            this.state.view = view;

            const zones = await this.orm.searchRead(
                "vertikali.polygon", [["view_id", "=", viewId]],
                ["name", "floor", "points", "target_view_id", "product_tmpl_id"],
                { order: "sequence, id" }
            );

            // Parse once here rather than on every render.
            this.state.zones = zones.map((z) => {
                let pts = [];
                try {
                    pts = JSON.parse(z.points || "[]");
                } catch {
                    pts = [];
                }
                return { ...z, pointsAttr: pts.map((p) => p.join(",")).join(" ") };
            });
        } catch (e) {
            this.state.error = e.message || String(e);
        } finally {
            this.state.loading = false;
        }
    }

    get imageSrc() {
        const v = this.state.view;
        if (!v) {
            return null;
        }
        return v.image
            ? `data:image/png;base64,${v.image}`
            : null;
    }

    onZoneClick(zone) {
        this.state.selected = zone;
        // A zone either drills into another view or opens a unit.
        if (zone.target_view_id) {
            this.loadView(zone.target_view_id[0]);
        }
    }

    openUnit(zone) {
        if (!zone.product_tmpl_id) {
            return;
        }
        this.action.doAction({
            type: "ir.actions.act_window",
            res_model: "product.template",
            res_id: zone.product_tmpl_id[0],
            views: [[false, "form"]],
            target: "current",
        });
    }

    /** Units on the floor a facade zone represents. */
    async showFloorUnits(zone) {
        if (!zone.floor) {
            return;
        }
        const domain = [["vk_is_unit", "=", true], ["vk_floor", "=", zone.floor]];
        if (this.state.view?.building) {
            domain.push(["vk_building", "=", this.state.view.building]);
        }
        this.action.doAction({
            type: "ir.actions.act_window",
            name: `Floor ${zone.floor}`,
            res_model: "product.template",
            domain,
            views: [[false, "list"], [false, "form"]],
            target: "current",
        });
    }
}

registry.category("actions").add("vertikali_selector", VertikaliSelector);
