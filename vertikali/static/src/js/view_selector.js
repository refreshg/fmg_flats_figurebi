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
        await this.createZone(pts);
    }

    /** Persist a shape and select it. Shared by drawing and duplicating. */
    async createZone(pts, name) {
        try {
            const id = await this.orm.create("vertikali.polygon", [{
                name: name || `Zone ${this.state.zones.length + 1}`,
                view_id: this.state.view.id,
                points: JSON.stringify(pts),
            }]);
            const [rec] = await this.orm.read(
                "vertikali.polygon", Array.isArray(id) ? id : [id],
                ["name", "floor", "points", "target_view_id", "product_tmpl_id"]
            );
            const zone = { ...rec, pts };
            this.state.zones.push(zone);
            this.state.selected = zone;
            return zone;
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
            return null;
        }
    }

    /**
     * Copy the selected zone, nudged down by its own height.
     *
     * This is the workhorse for a stepped facade: trace one band with as many
     * bends as the roofline needs, then duplicate it down the building. Each
     * copy keeps the outline, so only its position needs adjusting.
     */
    async duplicateDown() {
        const src = this.state.selected;
        if (!src) {
            this.notification.add("Select a zone to copy first.", { type: "warning" });
            return;
        }
        const step = this.bandStep(src);
        const pts = src.pts.map(([x, y]) => [
            x,
            Math.min(1, Math.round((y + step) * 10000) / 10000),
        ]);
        await this.createZone(pts);
    }

    /**
     * How far down one band sits from the next.
     *
     * Measured as the band's own thickness -- the vertical gap between its top
     * and bottom edge at the same x -- not its bounding-box height. On a
     * sloping or stepped band those differ a lot, and using the bounding box
     * pushes each copy far below where the next floor actually is.
     */
    bandStep(zone) {
        const pts = zone.pts;
        if (pts.length < 4) {
            const ys = pts.map((p) => p[1]);
            return Math.max(...ys) - Math.min(...ys);
        }
        // Split the outline into an upper and a lower chain: for each point,
        // decide which half it belongs to by comparing against the midline.
        const ys = pts.map((p) => p[1]);
        const mid = (Math.max(...ys) + Math.min(...ys)) / 2;
        const upper = pts.filter((p) => p[1] <= mid);
        const lower = pts.filter((p) => p[1] > mid);
        if (!upper.length || !lower.length) {
            return Math.max(...ys) - Math.min(...ys);
        }
        // Average thickness beats a single sample when the band is stepped.
        const avg = (arr) => arr.reduce((s, p) => s + p[1], 0) / arr.length;
        return Math.max(0.001, avg(lower) - avg(upper));
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

    /** Shift the selected zone by a small step, for fine alignment. */
    nudge(dy) {
        const z = this.state.selected;
        if (!z) {
            return;
        }
        z.pts = z.pts.map(([x, y]) => [
            x,
            Math.min(1, Math.max(0, Math.round((y + dy) * 10000) / 10000)),
        ]);
        this.state.dirty.add(z.id);
    }

    /** Clear the view so a facade can be re-traced from scratch. */
    async deleteAllZones() {
        const ids = this.state.zones.map((z) => z.id);
        if (!ids.length) {
            return;
        }
        if (!window.confirm(`Delete all ${ids.length} zones on this view?`)) {
            return;
        }
        try {
            await this.orm.unlink("vertikali.polygon", ids);
            this.state.zones = [];
            this.state.selected = null;
            this.state.dirty = new Set();
            this.notification.add(`Deleted ${ids.length} zones.`, { type: "success" });
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
     * Insert a point midway along the edge that follows `index`, so a zone can
     * be bent to follow a stepped roofline instead of being stuck as a quad.
     */
    addPointAfter(zone, index) {
        const a = zone.pts[index];
        const b = zone.pts[(index + 1) % zone.pts.length];
        const mid = [
            Math.round(((a[0] + b[0]) / 2) * 10000) / 10000,
            Math.round(((a[1] + b[1]) / 2) * 10000) / 10000,
        ];
        zone.pts.splice(index + 1, 0, mid);
        this.state.dirty.add(zone.id);
    }

    removePoint(zone, index) {
        if (zone.pts.length <= 3) {
            this.notification.add("A zone needs at least 3 points.", { type: "warning" });
            return;
        }
        zone.pts.splice(index, 1);
        this.state.dirty.add(zone.id);
    }

    /** Midpoints of every edge, used to render the "add point" handles. */
    edgeMidpoints(pts) {
        return pts.map((p, i) => {
            const q = pts[(i + 1) % pts.length];
            return { i, x: (p[0] + q[0]) / 2, y: (p[1] + q[1]) / 2 };
        });
    }

    /**
     * Lay the zones out between the first and last, interpolating point by
     * point. Placing the top and bottom floor then spreads the rest along the
     * render's perspective instead of dragging all 21 by hand.
     *
     * Works with any point count as long as the two reference zones agree:
     * a stepped roofline needs the same bend on both ends to interpolate.
     */
    distributeBetweenEnds() {
        const zones = this.state.zones;
        if (zones.length < 3) {
            this.notification.add(
                "Need at least 3 zones to distribute.", { type: "warning" });
            return;
        }
        const first = zones[0];
        const last = zones[zones.length - 1];
        if (first.pts.length !== last.pts.length) {
            this.notification.add(
                `The first zone has ${first.pts.length} points and the last has ` +
                `${last.pts.length}. Give both the same number of points ` +
                `(use the small + handles on the edges), then distribute.`,
                { type: "warning" }
            );
            return;
        }
        const n = zones.length - 1;
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

    /**
     * Stack N copies of the selected zone downwards, each offset by one band
     * height. Traces the whole facade from a single hand-drawn band.
     */
    async repeatDown() {
        const src = this.state.selected;
        if (!src) {
            this.notification.add("Select a zone to repeat first.", { type: "warning" });
            return;
        }
        const answer = window.prompt("How many copies below this one?", "20");
        if (!answer) {
            return;
        }
        const count = Math.max(1, Math.min(60, parseInt(answer, 10) || 0));
        const step = this.bandStep(src);

        const vals = [];
        for (let i = 1; i <= count; i++) {
            const pts = src.pts.map(([x, y]) => [
                x,
                Math.min(1, Math.round((y + step * i) * 10000) / 10000),
            ]);
            // Stop once a copy would fall off the bottom of the image.
            if (Math.min(...pts.map((p) => p[1])) >= 1) {
                break;
            }
            vals.push({
                name: `${src.name} +${i}`,
                view_id: this.state.view.id,
                points: JSON.stringify(pts),
            });
        }
        if (!vals.length) {
            this.notification.add("No room left below this zone.", { type: "warning" });
            return;
        }
        try {
            const ids = await this.orm.create("vertikali.polygon", vals);
            const recs = await this.orm.read(
                "vertikali.polygon", ids,
                ["name", "floor", "points", "target_view_id", "product_tmpl_id"]
            );
            for (const rec of recs) {
                this.state.zones.push({ ...rec, pts: this.parsePoints(rec.points) });
            }
            this.notification.add(`Added ${recs.length} copies.`, { type: "success" });
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    /**
     * Copy the selected zone's outline onto every other zone, keeping each
     * one's vertical position. Shaping one band around a stepped roofline and
     * applying it everywhere beats repeating the same bends 21 times.
     */
    applyShapeToAll() {
        const src = this.state.selected;
        if (!src) {
            this.notification.add("Select the zone to copy first.", { type: "warning" });
            return;
        }
        const srcTop = Math.min(...src.pts.map((p) => p[1]));
        let n = 0;
        for (const z of this.state.zones) {
            if (z.id === src.id) {
                continue;
            }
            // Offset by the difference in vertical position, so each band
            // keeps its own floor while adopting the outline.
            const dy = Math.min(...z.pts.map((p) => p[1])) - srcTop;
            z.pts = src.pts.map(([x, y]) => [
                x,
                Math.min(1, Math.max(0, Math.round((y + dy) * 10000) / 10000)),
            ]);
            this.state.dirty.add(z.id);
            n++;
        }
        this.notification.add(`Applied the outline to ${n} zone(s).`, { type: "success" });
    }
}

registry.category("actions").add("vertikali_selector", VertikaliSelector);
