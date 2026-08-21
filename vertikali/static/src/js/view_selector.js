/** @odoo-module **/

import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { Component, onWillStart, useRef, useState } from "@odoo/owl";

/**
 * Renders a vertikali.view image with its polygons drawn on top as clickable
 * SVG regions, and lets a manager reshape or draw those regions in place.
 *
 * Geometry: points are stored normalized (0..1) against the *image*, not the
 * container. The SVG is sized and positioned onto the rendered image box
 * (letterboxed by object-fit: contain), so a zone stays glued to the same spot
 * on the render at any window size or aspect ratio. Stretching the SVG over
 * the container instead would drift as soon as the two ratios differ.
 *
 * Real renders are photographs in perspective: floors slope and wings sit at
 * different heights, so zones are arbitrary quadrilaterals dragged into place
 * rather than generated bands.
 */
export class VertikaliSelector extends Component {
    static template = "vertikali.Selector";
    static props = { ...Component.props, action: { type: Object, optional: true } };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.notification = useService("notification");
        this.imgRef = useRef("img");
        this.stageRef = useRef("stage");

        this.state = useState({
            views: [],
            view: null,
            zones: [],
            selected: null,
            loading: true,
            error: null,
            // editor
            editing: false,
            drawing: false,
            draft: [],
            dirty: new Set(),
            // rendered image box within the stage, in CSS pixels
            box: { left: 0, top: 0, width: 0, height: 0 },
        });

        this.onResize = () => this.measure();

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

    // ---------------------------------------------------------------- data

    async loadView(viewId) {
        this.state.loading = true;
        this.state.selected = null;
        this.state.draft = [];
        this.state.drawing = false;
        this.state.dirty = new Set();
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
            this.state.zones = zones.map((z) => ({ ...z, pts: this.parsePoints(z.points) }));
        } catch (e) {
            this.state.error = e.message || String(e);
        } finally {
            this.state.loading = false;
        }
    }

    parsePoints(raw) {
        try {
            const p = JSON.parse(raw || "[]");
            return Array.isArray(p) ? p : [];
        } catch {
            return [];
        }
    }

    attr(pts) {
        return pts.map((p) => p.join(",")).join(" ");
    }

    get imageSrc() {
        const v = this.state.view;
        return v && v.image ? `data:image/png;base64,${v.image}` : null;
    }

    // ------------------------------------------------------------ geometry

    /**
     * Compute where the image actually lands inside the stage. object-fit:
     * contain letterboxes it, so the drawn box is usually smaller than the
     * container -- the overlay has to match the box, not the container.
     */
    measure() {
        const img = this.imgRef.el;
        const stage = this.stageRef.el;
        if (!img || !stage || !img.naturalWidth) {
            return;
        }
        const sr = stage.getBoundingClientRect();
        const scale = Math.min(sr.width / img.naturalWidth, sr.height / img.naturalHeight);
        const w = img.naturalWidth * scale;
        const h = img.naturalHeight * scale;
        this.state.box = {
            left: (sr.width - w) / 2,
            top: (sr.height - h) / 2,
            width: w,
            height: h,
        };
    }

    onImageLoad() {
        this.measure();
        // Keep the overlay glued to the image as the layout changes.
        if (!this._observer && this.stageRef.el && window.ResizeObserver) {
            this._observer = new ResizeObserver(() => this.measure());
            this._observer.observe(this.stageRef.el);
        }
    }

    /** Pointer position as a 0..1 coordinate on the image. */
    toNorm(ev) {
        const { left, top, width, height } = this.state.box;
        const sr = this.stageRef.el.getBoundingClientRect();
        const x = (ev.clientX - sr.left - left) / width;
        const y = (ev.clientY - sr.top - top) / height;
        return [
            Math.min(1, Math.max(0, Math.round(x * 10000) / 10000)),
            Math.min(1, Math.max(0, Math.round(y * 10000) / 10000)),
        ];
    }

    // -------------------------------------------------------------- select

    onZoneClick(zone) {
        if (this.state.drawing) {
            return;
        }
        this.state.selected = zone;
        if (!this.state.editing && zone.target_view_id) {
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

    showFloorUnits(zone) {
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

    // -------------------------------------------------------------- editor

    toggleEdit() {
        this.state.editing = !this.state.editing;
        this.state.drawing = false;
        this.state.draft = [];
        this.measure();
    }

    startDraw() {
        this.state.drawing = true;
        this.state.draft = [];
        this.state.selected = null;
    }

    onStageClick(ev) {
        if (!this.state.editing || !this.state.drawing) {
            return;
        }
        const p = this.toNorm(ev);
        // Closing on the first point finishes the shape.
        if (this.state.draft.length >= 3) {
            const [fx, fy] = this.state.draft[0];
            if (Math.hypot(p[0] - fx, p[1] - fy) < 0.015) {
                this.finishDraw();
                return;
            }
        }
        this.state.draft.push(p);
    }

    async finishDraw() {
        if (this.state.draft.length < 3) {
            this.notification.add("A zone needs at least 3 points.", { type: "warning" });
            return;
        }
        const pts = [...this.state.draft];
        this.state.draft = [];
        this.state.drawing = false;
        try {
            const id = await this.orm.create("vertikali.polygon", [{
                name: `Zone ${this.state.zones.length + 1}`,
                view_id: this.state.view.id,
                points: JSON.stringify(pts),
            }]);
            const [rec] = await this.orm.read(
                "vertikali.polygon", id,
                ["name", "floor", "points", "target_view_id", "product_tmpl_id"]
            );
            const zone = { ...rec, pts };
            this.state.zones.push(zone);
            this.state.selected = zone;
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    cancelDraw() {
        this.state.drawing = false;
        this.state.draft = [];
    }

    undoPoint() {
        this.state.draft.pop();
    }

    /** Drag one vertex of the selected zone. */
    startDragVertex(ev, zone, index) {
        if (!this.state.editing) {
            return;
        }
        ev.preventDefault();
        ev.stopPropagation();
        const move = (e) => {
            zone.pts[index] = this.toNorm(e);
            this.state.dirty.add(zone.id);
        };
        const up = () => {
            window.removeEventListener("pointermove", move);
            window.removeEventListener("pointerup", up);
        };
        window.addEventListener("pointermove", move);
        window.addEventListener("pointerup", up);
    }

    /** Drag the whole zone. */
    startDragZone(ev, zone) {
        if (!this.state.editing || this.state.drawing) {
            return;
        }
        ev.preventDefault();
        this.state.selected = zone;
        const origin = this.toNorm(ev);
        const start = zone.pts.map((p) => [...p]);
        const move = (e) => {
            const now = this.toNorm(e);
            const dx = now[0] - origin[0];
            const dy = now[1] - origin[1];
            zone.pts = start.map(([x, y]) => [
                Math.min(1, Math.max(0, Math.round((x + dx) * 10000) / 10000)),
                Math.min(1, Math.max(0, Math.round((y + dy) * 10000) / 10000)),
            ]);
            this.state.dirty.add(zone.id);
        };
        const up = () => {
            window.removeEventListener("pointermove", move);
            window.removeEventListener("pointerup", up);
        };
        window.addEventListener("pointermove", move);
        window.addEventListener("pointerup", up);
    }

    async saveShapes() {
        const ids = [...this.state.dirty];
        if (!ids.length) {
            this.notification.add("Nothing to save.", { type: "info" });
            return;
        }
        try {
            for (const id of ids) {
                const zone = this.state.zones.find((z) => z.id === id);
                if (zone) {
                    await this.orm.write("vertikali.polygon", [id], {
                        points: JSON.stringify(zone.pts),
                    });
                }
            }
            this.state.dirty = new Set();
            this.notification.add(`Saved ${ids.length} zone(s).`, { type: "success" });
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    async deleteZone(zone) {
        try {
            await this.orm.unlink("vertikali.polygon", [zone.id]);
            this.state.zones = this.state.zones.filter((z) => z.id !== zone.id);
            this.state.dirty.delete(zone.id);
            if (this.state.selected?.id === zone.id) {
                this.state.selected = null;
            }
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    /**
     * Lay the zones out as evenly spaced bands between two reference zones.
     * Dragging the top and bottom floor into place and interpolating the rest
     * follows the render's perspective without dragging all 21 by hand.
     */
    distributeBetweenEnds() {
        const zones = this.state.zones.filter((z) => z.pts.length === 4);
        if (zones.length < 3) {
            this.notification.add(
                "Need at least 3 four-point zones to distribute.", { type: "warning" });
            return;
        }
        const first = zones[0];
        const last = zones[zones.length - 1];
        const n = zones.length - 1;
        // Corner-wise interpolation, so a sloping roofline stays sloping.
        zones.forEach((z, i) => {
            if (i === 0 || i === n) {
                return;
            }
            const t = i / n;
            z.pts = first.pts.map((p, c) => [
                Math.round((p[0] + (last.pts[c][0] - p[0]) * t) * 10000) / 10000,
                Math.round((p[1] + (last.pts[c][1] - p[1]) * t) * 10000) / 10000,
            ]);
            this.state.dirty.add(z.id);
        });
        this.notification.add(
            `Distributed ${n - 1} zone(s) between the first and last.`,
            { type: "success" });
    }
}

registry.category("actions").add("vertikali_selector", VertikaliSelector);
