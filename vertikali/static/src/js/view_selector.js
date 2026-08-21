/** @odoo-module **/

import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { Component, onWillStart, onWillUnmount, useRef, useState } from "@odoo/owl";

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
            projects: [],
            project: null,
            blocks: [],
            block: null,
            mode: null,          // masterplan | facade | floor | grid
            views: [],
            view: null,
            zones: [],
            units: [],           // grid mode
            unit: null,          // unit shown in the detail panel
            filters: { rooms: [], status: [], areaMin: null, areaMax: null, priceMax: null },
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

        // Delete removes the selected zone while editing; Escape cancels a
        // draw. Bound on the document so it works wherever focus sits.
        this.onKeydown = (ev) => {
            if (!this.state.editing) {
                return;
            }
            if (ev.key === "Escape" && this.state.drawing) {
                this.cancelDraw();
                return;
            }
            const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(ev.target?.tagName || "");
            if ((ev.key === "Delete" || ev.key === "Backspace")
                    && this.state.selected && !this.state.drawing && !typing) {
                ev.preventDefault();
                this.deleteZone(this.state.selected);
            }
        };
        document.addEventListener("keydown", this.onKeydown);
        onWillUnmount(() => {
            document.removeEventListener("keydown", this.onKeydown);
            this._observer?.disconnect();
        });

        onWillStart(async () => {
            try {
                this.state.projects = await this.orm.searchRead(
                    "vertikali.project", [],
                    ["name", "building", "tagline", "description", "handover",
                     "image", "unit_count", "available_count", "price_from",
                     "use_masterplan", "use_facade", "use_floorplan", "use_grid"],
                    { order: "sequence, id" }
                );
                this.state.blocks = await this.orm.searchRead(
                    "vertikali.block", [],
                    ["name", "code", "project_id", "color", "floors", "points",
                     "facade_view_id", "unit_count", "available_count"],
                    { order: "sequence, code" }
                );
                const views = await this.orm.searchRead(
                    "vertikali.view", [],
                    ["name", "view_type", "building", "floor", "project_id"],
                    { order: "view_type, sequence, id" }
                );
                this.state.views = views;

                // Start on the chooser when there is a choice to make;
                // a single project goes straight in.
                if (this.state.projects.length === 1) {
                    await this.selectProject(this.state.projects[0]);
                } else if (!this.state.projects.length && views.length) {
                    await this.loadView(views[0].id);
                }
            } catch (e) {
                this.state.error = e.message || String(e);
            } finally {
                this.state.loading = false;
            }
        });
    }

    // ------------------------------------------------------------- steps

    /** Steps this project switched on, in navigation order. */
    get steps() {
        const p = this.state.project;
        const all = [
            { key: "masterplan", label: "Masterplan", icon: "▦", on: p?.use_masterplan },
            { key: "facade", label: "Facade", icon: "▤", on: p?.use_facade },
            { key: "floor", label: "Floor plans", icon: "▣", on: p?.use_floorplan },
            { key: "grid", label: "Grid", icon: "⊞", on: p?.use_grid },
        ];
        return p ? all.filter((s) => s.on) : all;
    }

    /** Views for the current project, mode and (if chosen) block. */
    get modeViews() {
        const block = this.state.block;
        return this.state.views.filter((v) => {
            if (v.view_type !== this.state.mode) {
                return false;
            }
            if (this.state.project && v.project_id?.[0] !== this.state.project.id) {
                return false;
            }
            // Views carrying a building label belong to that block only.
            if (block && v.building && v.building !== block.code) {
                return false;
            }
            return true;
        });
    }

    /** Blocks of the current project. */
    get projectBlocks() {
        const p = this.state.project;
        return p ? this.state.blocks.filter((b) => b.project_id?.[0] === p.id) : [];
    }

    async selectProject(project) {
        this.state.project = project;
        this.state.block = null;
        this.state.unit = null;
        const blocks = this.projectBlocks;
        // With several blocks, the masterplan is where you pick one.
        if (blocks.length > 1 && project.use_masterplan) {
            this.state.mode = "masterplan";
            this.state.view = null;
            this.state.zones = [];
            return;
        }
        if (blocks.length) {
            await this.selectBlock(blocks[0]);
            return;
        }
        const steps = this.steps;
        await this.setMode(steps.length ? steps[0].key : null);
    }

    async selectBlock(block) {
        this.state.block = block;
        const steps = this.steps.filter((s) => s.key !== "masterplan");
        await this.setMode(steps.length ? steps[0].key : null);
    }

    backToProjects() {
        this.state.project = null;
        this.state.block = null;
        this.state.mode = null;
        this.state.view = null;
        this.state.unit = null;
        this.state.zones = [];
        this.state.units = [];
    }

    async setMode(mode) {
        this.state.mode = mode;
        this.state.selected = null;
        this.state.view = null;
        this.state.zones = [];
        this.state.units = [];
        if (!mode) {
            return;
        }
        if (mode === "grid") {
            await this.loadGrid();
            return;
        }
        const views = this.modeViews;
        if (views.length) {
            await this.loadView(views[0].id);
        }
    }

    /** Grid mode reads the units directly -- no image involved. */
    async loadGrid() {
        this.state.loading = true;
        try {
            // The chosen block wins over the project's own label, so a
            // multi-block project shows one tower at a time.
            const domain = [["vk_is_unit", "=", true]];
            const building = this.state.block?.code || this.state.project?.building;
            if (building) {
                domain.push(["vk_building", "=", building]);
            }
            this.state.units = await this.orm.searchRead(
                "product.template", domain,
                ["default_code", "vk_floor", "vk_section", "vk_rooms",
                 "vk_area_total", "vk_area_balcony", "vk_orientation",
                 "list_price", "vk_price_sqm", "vk_state", "vk_handover"],
                { order: "vk_floor desc, vk_section, default_code" }
            );
        } catch (e) {
            this.state.error = e.message || String(e);
        } finally {
            this.state.loading = false;
        }
    }

    /** Distinct layouts present, for the filter chips. */
    get layouts() {
        return [...new Set(this.state.units.map((u) => u.vk_rooms).filter(Boolean))].sort();
    }

    /** Sections present, in natural order. */
    get sections() {
        const found = [...new Set(this.state.units.map((u) => u.vk_section || ""))];
        return found.sort((a, b) => String(a).localeCompare(String(b), undefined, { numeric: true }));
    }

    matchesFilters(u) {
        const f = this.state.filters;
        if (f.rooms.length && !f.rooms.includes(u.vk_rooms)) {
            return false;
        }
        if (f.status.length && !f.status.includes(u.vk_state)) {
            return false;
        }
        if (f.areaMin && u.vk_area_total < f.areaMin) {
            return false;
        }
        if (f.areaMax && u.vk_area_total > f.areaMax) {
            return false;
        }
        if (f.priceMax && u.list_price > f.priceMax) {
            return false;
        }
        return true;
    }

    toggleFilter(kind, value) {
        const list = this.state.filters[kind];
        const i = list.indexOf(value);
        if (i >= 0) {
            list.splice(i, 1);
        } else {
            list.push(value);
        }
    }

    clearFilters() {
        this.state.filters.rooms = [];
        this.state.filters.status = [];
        this.state.filters.areaMin = null;
        this.state.filters.areaMax = null;
        this.state.filters.priceMax = null;
    }

    get filterActive() {
        const f = this.state.filters;
        return !!(f.rooms.length || f.status.length || f.areaMin || f.areaMax || f.priceMax);
    }

    get matchCount() {
        return this.state.units.filter((u) => this.matchesFilters(u)).length;
    }

    /**
     * Floors down the page, sections across, units within each section.
     *
     * Filtered-out units keep their cell rather than disappearing: a grid whose
     * columns reflow on every filter change is unreadable, so they are dimmed
     * in place and the layout stays put.
     */
    get gridRows() {
        const sections = this.sections;
        const byFloor = new Map();
        for (const u of this.state.units) {
            if (!byFloor.has(u.vk_floor)) {
                byFloor.set(u.vk_floor, new Map());
            }
            const key = u.vk_section || "";
            const row = byFloor.get(u.vk_floor);
            if (!row.has(key)) {
                row.set(key, []);
            }
            row.get(key).push(u);
        }
        return [...byFloor.entries()]
            .sort((a, b) => b[0] - a[0])
            .map(([floor, row]) => ({
                floor,
                free: [...row.values()].flat()
                    .filter((u) => u.vk_state === "available").length,
                cells: sections.map((s) => ({
                    section: s,
                    units: (row.get(s) || []).map((u) => ({
                        ...u,
                        dimmed: !this.matchesFilters(u),
                    })),
                })),
            }));
    }

    /** Short label inside a cell: room count reads faster than a code. */
    cellLabel(unit) {
        const r = unit.vk_rooms || "";
        if (r === "studio") {
            return "S";
        }
        if (r === "commercial") {
            return "C";
        }
        const n = parseInt(r, 10);
        return Number.isNaN(n) ? "·" : String(n);
    }

    selectUnit(unit) {
        this.state.unit = unit;
    }

    openUnitRecord(unit) {
        this.action.doAction({
            type: "ir.actions.act_window",
            res_model: "product.template",
            res_id: unit.id,
            views: [[false, "form"]],
            target: "current",
        });
    }

    fmtMoney(v) {
        return (v || 0).toLocaleString(undefined, { maximumFractionDigits: 0 });
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

    /** Project cover, used on the chooser and as the masterplan backdrop. */
    coverSrc(project) {
        return project?.image ? `data:image/png;base64,${project.image}` : null;
    }

    pointsAttr(raw) {
        try {
            const p = JSON.parse(raw || "[]");
            return Array.isArray(p) ? p.map((q) => q.join(",")).join(" ") : "";
        } catch {
            return "";
        }
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
        if (this.state.editing) {
            return;
        }
        // Drill down: a zone opens its target view, or the unit it holds.
        if (zone.target_view_id) {
            this.state.mode = "floor";
            this.loadView(zone.target_view_id[0]);
        } else if (zone.product_tmpl_id) {
            this.openUnit(zone);
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
        if (pts.length < 3) {
            return 0.02;
        }
        // Measure the band vertically at several x positions and take the
        // median. Splitting the outline into "upper" and "lower" halves by a
        // midline fails on a sloping band, where a left-hand top point can sit
        // below a right-hand bottom one; a vertical cut never has that problem.
        const xs = pts.map((p) => p[0]);
        const x0 = Math.min(...xs);
        const x1 = Math.max(...xs);
        if (x1 - x0 < 1e-6) {
            const ys = pts.map((p) => p[1]);
            return Math.max(0.001, Math.max(...ys) - Math.min(...ys));
        }

        const samples = [];
        const SAMPLES = 9;
        for (let s = 1; s <= SAMPLES; s++) {
            const x = x0 + ((x1 - x0) * s) / (SAMPLES + 1);
            // Every y where an edge crosses this vertical line.
            const hits = [];
            for (let i = 0; i < pts.length; i++) {
                const [ax, ay] = pts[i];
                const [bx, by] = pts[(i + 1) % pts.length];
                if ((ax <= x && bx > x) || (bx <= x && ax > x)) {
                    hits.push(ay + ((x - ax) / (bx - ax)) * (by - ay));
                }
            }
            if (hits.length >= 2) {
                samples.push(Math.max(...hits) - Math.min(...hits));
            }
        }
        if (!samples.length) {
            const ys = pts.map((p) => p[1]);
            return Math.max(0.001, Math.max(...ys) - Math.min(...ys));
        }
        samples.sort((a, b) => a - b);
        return Math.max(0.001, samples[Math.floor(samples.length / 2)]);
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
