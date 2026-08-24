/** @odoo-module **/

import { registry } from "@web/core/registry";
import { useService } from "@web/core/utils/hooks";
import { Component, onWillStart, onWillUnmount, useRef, useState } from "@odoo/owl";

/**
 * Renders a vertikali.view image with its polygons drawn on top as clickable
 * SVG regions, and lets a manager reshape or draw those regions in place.
 *
 * Geometry: points are stored normalized (0..1) against the *image*. The image
 * and the SVG share one CSS grid cell, so the browser keeps the overlay
 * exactly on the picture and clicks normalize against that same frame --
 * measuring the picture in JS and positioning the overlay from it meant any
 * stale layout showed up as a drifted, wrongly-proportioned overlay.
 *
 * Real renders are photographs in perspective: floors slope and wings sit at
 * different heights, so zones are arbitrary quadrilaterals dragged into place
 * rather than generated bands.
 */
// The filter groups the gear can show or hide, in bar order.
export const FILTER_GROUPS = [
    { key: "layout", label: "Layout" },
    { key: "status", label: "Status" },
    { key: "orient", label: "Orientation" },
    { key: "cond", label: "Condition" },
    { key: "vview", label: "View" },
    { key: "area", label: "m²" },
    { key: "price", label: "Max price" },
];

const FILTER_VIS_KEY = "vertikali.filterVis";

/** The user's saved choice of visible filter groups; everything on first. */
function loadFilterVis() {
    const vis = Object.fromEntries(FILTER_GROUPS.map((g) => [g.key, true]));
    try {
        Object.assign(vis, JSON.parse(window.localStorage.getItem(FILTER_VIS_KEY) || "{}"));
    } catch {
        // Corrupt storage falls back to everything visible.
    }
    return vis;
}

export class VertikaliSelector extends Component {
    static template = "vertikali.Selector";
    PAGE_SIZE = 100;
    static props = { ...Component.props, action: { type: Object, optional: true } };

    setup() {
        this.orm = useService("orm");
        this.action = useService("action");
        this.notification = useService("notification");
        this.frameRef = useRef("frame");
        this.stageRef = useRef("stage");

        // Launched from an opportunity: pick mode adds an Attach button to
        // the unit card, focus mode opens on the attached units' floor with
        // their zones outlined. Plain menu launches carry no params.
        // Params vanish when the action is restored from the URL (breadcrumb
        // back, reload), so a launch that has them stashes the context and a
        // launch that lacks them recovers it. backToOrigin clears the stash.
        let params = this.props.action?.params || {};
        try {
            if (params.vk_focus_unit_ids?.length || params.vk_pick_model) {
                window.sessionStorage.setItem(
                    "vertikali.ctx", JSON.stringify(params));
            } else {
                params = JSON.parse(
                    window.sessionStorage.getItem("vertikali.ctx") || "{}");
            }
        } catch {
            // Storage unavailable: deep links just do not survive a reload.
        }
        // Pick mode: chosen units land on this record -- a lead's unit list
        // or a quotation's order lines, same flow either way.
        this.pick = params.vk_pick_model ? {
            model: params.vk_pick_model,
            id: params.vk_pick_id,
            name: params.vk_pick_name || "",
        } : null;
        this.focusUnitIds = params.vk_focus_unit_ids || [];
        // Where the selector was opened from (a lead or an order), so a
        // back button can return there in one click.
        this.origin = params.vk_origin_model ? {
            model: params.vk_origin_model,
            id: params.vk_origin_id,
            name: params.vk_origin_name || "",
        } : null;

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
            floorUnits: [],      // units on the open floor plan
            unitById: {},
            unit: null,          // unit shown in the detail panel
            card: null,          // unit opened as a full card
            cardLeads: [],       // opportunities already tied to that unit
            cardOrders: [],      // sale orders carrying it
            gallery: [],         // the card's images
            slide: 0,            // which one is showing
            zoom: false,         // the current image, full screen
            editingBlock: null,  // block whose masterplan shape is being drawn
            tip: null,           // hovered band, for the floor tooltip
            cellTip: null,       // hovered grid cell, for the unit tooltip
            sortBy: "default_code",
            sortAsc: true,
            page: 0,             // properties table page
            unitTotal: 0,        // count for the inventory tab badges
            zoneUnits: [],       // units behind the selected facade band
            floorPick: [],       // every unit on that storey, for ticking
            zonePlan: null,      // that floor's plan, shown beside them
            filters: { rooms: [], status: [], orient: [], cond: [], vview: [],
                       areaMin: null, areaMax: null, priceMax: null },
            // Which filter groups show, chosen by the user via the gear and
            // remembered per browser.
            filterVis: loadFilterVis(),
            filterCfg: false,    // the gear popover
            selected: null,
            loading: true,
            error: null,
            // Units to outline on the plan (from the opportunity). A Set so
            // attaching more units in pick mode lights them up immediately.
            focusUnits: new Set(this.focusUnitIds),
            // Their floor/building/section, so the facade bands, masterplan
            // blocks and grid cells can carry the outline too.
            focusInfo: [],
            // editor
            editing: false,
            drawing: false,
            draft: [],
            dirty: new Set(),
        });

        // Delete removes the selected zone while editing; Escape cancels a
        // draw. Bound on the document so it works wherever focus sits.
        this.onKeydown = (ev) => {
            // The card and its lightbox come first: while one is open it owns
            // the keyboard, so Escape backs out one layer at a time.
            if (this.state.zoom) {
                if (ev.key === "Escape") {
                    this.closeZoom();
                } else if (ev.key === "ArrowLeft") {
                    this.goSlide(this.state.slide - 1);
                } else if (ev.key === "ArrowRight") {
                    this.goSlide(this.state.slide + 1);
                }
                return;
            }
            if (this.state.card) {
                if (ev.key === "Escape") {
                    this.closeCard();
                }
                return;
            }
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
        });

        onWillStart(async () => {
            try {
                // No image field here on purpose: a cover is a few megabytes
                // of base64 and fetching one per project blocked the first
                // paint for seconds. The chooser uses /web/image URLs, and
                // the full cover is read only when a masterplan opens.
                this.state.projects = await this.orm.searchRead(
                    "vertikali.project", [],
                    ["name", "building", "tagline", "description", "handover",
                     "unit_count", "available_count", "price_from",
                     "use_masterplan", "use_facade", "use_floorplan", "use_grid",
                     "has_image", "write_date"],
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
                    ["name", "view_type", "building", "floor", "section",
                     "project_id"],
                    { order: "view_type, sequence, id" }
                );
                this.state.views = views;

                // Always start on the project chooser. Skipping it for a lone
                // project dropped the user straight into a facade with no
                // sense of where they were or how to get back out.
                if (!this.state.projects.length && views.length) {
                    await this.loadView(views[0].id);
                }

                // Launched from an opportunity with units attached: skip the
                // chooser and land on their floor plan, zones outlined.
                if (this.focusUnitIds.length) {
                    await this.openFocusUnits();
                } else {
                    // A reload otherwise dumps the user back on the project
                    // chooser -- put them back where they stood.
                    await this.restoreNav();
                }
            } catch (e) {
                this.state.error = e.message || String(e);
            } finally {
                this.state.loading = false;
            }
        });
    }

    // ------------------------------------------------------------- steps

    /**
     * Steps this project switched on, in navigation order.
     *
     * Grid+ and Properties are two more readings of the same inventory, so
     * they ride on use_grid rather than needing switches of their own.
     */
    get steps() {
        const p = this.state.project;
        const all = [
            { key: "masterplan", label: "Masterplan", icon: "▦", on: p?.use_masterplan },
            { key: "facade", label: "Facades", icon: "▤", on: p?.use_facade },
            { key: "grid", label: "Grid", icon: "▩", on: p?.use_grid, count: true },
            { key: "gridplus", label: "Grid+", icon: "◱", on: p?.use_grid, count: true },
            { key: "properties", label: "Properties", icon: "☰", on: p?.use_grid, count: true },
            { key: "floor", label: "Floors", icon: "▣", on: p?.use_floorplan },
        ];
        return p ? all.filter((s) => s.on) : all;
    }

    /** Inventory-backed steps share one dataset. */
    get isInventoryMode() {
        return ["grid", "gridplus", "properties"].includes(this.state.mode);
    }

    /** Units in scope, for the badge on the inventory tabs. */
    get inventoryCount() {
        return this.state.units.length || this.state.unitTotal || 0;
    }

    /**
     * Count the units of the current block without loading them, so the tabs
     * can show a figure before one of them is opened.
     */
    async refreshUnitTotal() {
        const domain = [["vk_is_unit", "=", true]];
        const building = this.state.block?.code || this.state.project?.building;
        if (building) {
            domain.push(["vk_building", "=", building]);
        }
        try {
            this.state.unitTotal = await this.orm.searchCount(
                "product.template", domain);
        } catch {
            this.state.unitTotal = 0;
        }
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

    /**
     * Hover tooltip for a facade band: which storey, and what is left on it.
     * Anchored to the band's own centre so it follows the shape.
     */
    showZoneTip(zone, ev) {
        if (this.state.editing || this.state.drawing || !zone.pts?.length) {
            return;
        }
        const xs = zone.pts.map((p) => p[0]);
        const ys = zone.pts.map((p) => p[1]);
        this.state.tip = {
            zone,
            x: (Math.min(...xs) + Math.max(...xs)) / 2,
            y: (Math.min(...ys) + Math.max(...ys)) / 2,
        };

        // Stored counts only cover attached units. When a band has none, read
        // the floor instead, so hovering still answers the question.
        if (!zone.unit_count && zone.floor && !zone._tipLoaded) {
            zone._tipLoaded = true;
            this.unitsOnFloorFull(zone).then((rows) => {
                const n = (s) => rows.filter((u) => u.vk_state === s).length;
                const prices = rows
                    .filter((u) => u.vk_state === "available")
                    .map((u) => u.list_price);
                Object.assign(zone, {
                    unit_count: rows.length,
                    available_count: n("available"),
                    reserved_count: n("reserved"),
                    sold_count: n("sold"),
                    price_from: prices.length ? Math.min(...prices) : 0,
                });
            }).catch(() => {});
        }
    }

    /** Units matching a band's floor and section, with status and price. */
    async unitsOnFloorFull(zone) {
        const domain = [["vk_is_unit", "=", true], ["vk_floor", "=", zone.floor]];
        if (zone.section) {
            domain.push(["vk_section", "=", zone.section]);
        }
        const building = this.state.block?.code || this.state.view?.building;
        if (building) {
            domain.push(["vk_building", "=", building]);
        }
        return this.orm.searchRead(
            "product.template", domain, ["vk_state", "list_price"]);
    }

    hideZoneTip() {
        this.state.tip = null;
    }

    /** Zone editing only makes sense where zones exist. */
    get isZoneMode() {
        return this.state.mode === "facade" || this.state.mode === "floor";
    }

    // ------------------------------------------------- masterplan editing

    /**
     * Blocks are shapes on the project cover, not vertikali.polygon records,
     * so they need their own draw/drag/delete path rather than reusing the
     * zone editor.
     */
    startBlockDraw(block) {
        this.state.editingBlock = block;
        this.state.drawing = true;
        this.state.draft = [];
    }

    /**
     * Draw a shape for a new block. The number of towers is whatever has been
     * drawn, so a development can have one block or six without configuring a
     * fixed list first.
     */
    async startNewBlock() {
        const code = window.prompt("Block letter or number?", this.nextBlockCode());
        if (!code) {
            return;
        }
        try {
            const ids = await this.orm.create("vertikali.block", [{
                name: `Block ${code}`,
                code: code.trim(),
                project_id: this.state.project.id,
                sequence: (this.projectBlocks.length + 1) * 10,
                color: this.nextBlockColor(),
            }]);
            const [rec] = await this.orm.read(
                "vertikali.block", ids,
                ["name", "code", "project_id", "color", "floors", "points",
                 "facade_view_id", "unit_count", "available_count"]
            );
            this.state.blocks.push(rec);
            this.startBlockDraw(rec);
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    nextBlockCode() {
        const used = new Set(this.projectBlocks.map((b) => b.code));
        for (const c of "ABCDEFGHIJKLMNOP") {
            if (!used.has(c)) {
                return c;
            }
        }
        return String(this.projectBlocks.length + 1);
    }

    nextBlockColor() {
        const palette = ["#1aa179", "#e8a33d", "#3d7fc1", "#b0559b", "#c1543d", "#5aa832"];
        return palette[this.projectBlocks.length % palette.length];
    }

    async deleteBlock(block) {
        if (!window.confirm(`Delete block ${block.code} and its shape?`)) {
            return;
        }
        try {
            await this.orm.unlink("vertikali.block", [block.id]);
            this.state.blocks = this.state.blocks.filter((b) => b.id !== block.id);
            if (this.state.editingBlock?.id === block.id) {
                this.state.editingBlock = null;
            }
            if (this.state.block?.id === block.id) {
                this.state.block = null;
            }
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    async finishBlockDraw() {
        const block = this.state.editingBlock;
        if (!block) {
            return;
        }
        if (this.state.draft.length < 3) {
            this.notification.add("A shape needs at least 3 points.", { type: "warning" });
            return;
        }
        const pts = [...this.state.draft];
        this.state.draft = [];
        this.state.drawing = false;
        this.state.editingBlock = null;
        await this.saveBlockShape(block, pts);
    }

    async saveBlockShape(block, pts) {
        try {
            await this.orm.write("vertikali.block", [block.id], {
                points: JSON.stringify(pts),
            });
            block.points = JSON.stringify(pts);
            this.notification.add(`Shape saved for block ${block.code}.`, { type: "success" });
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    async clearBlockShape(block) {
        try {
            await this.orm.write("vertikali.block", [block.id], { points: false });
            block.points = false;
            this.notification.add(`Shape cleared for block ${block.code}.`, { type: "info" });
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    /** Drag one corner of a block outline. */
    startDragBlockVertex(ev, block, index) {
        ev.preventDefault();
        ev.stopPropagation();
        const pts = this.parsePoints(block.points);
        const move = (e) => {
            pts[index] = this.toNorm(e);
            block.points = JSON.stringify(pts);
        };
        const up = () => {
            window.removeEventListener("pointermove", move);
            window.removeEventListener("pointerup", up);
            this.saveBlockShape(block, this.parsePoints(block.points));
        };
        window.addEventListener("pointermove", move);
        window.addEventListener("pointerup", up);
    }

    blockPoints(block) {
        return this.parsePoints(block.points);
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
        this.refreshUnitTotal();
        // The masterplan is the project's own screen: it shows the site and
        // the blocks on it. Auto-entering a block skipped that entirely, even
        // when the project had one to show.
        if (project.use_masterplan) {
            this.state.mode = "masterplan";
            this.state.view = null;
            this.state.zones = [];
            this._saveNav();
            return;
        }
        const blocks = this.projectBlocks;
        if (blocks.length === 1) {
            await this.selectBlock(blocks[0]);
            return;
        }
        const steps = this.steps;
        await this.setMode(steps.length ? steps[0].key : null);
    }

    async selectBlock(block) {
        this.state.block = block;
        this.refreshUnitTotal();
        const steps = this.steps.filter((s) => s.key !== "masterplan");
        await this.setMode(steps.length ? steps[0].key : null);
    }

    /**
     * Back to the site plan from inside a block.
     *
     * A method rather than a multi-statement arrow in the template: OWL
     * compiles inline expressions, and a block of assignments there breaks
     * the generated function ("v36 is not a function").
     */
    /**
     * Load the view a <select> picked.
     *
     * The id is parsed here, not in the template: OWL evaluates template
     * expressions in a restricted scope where parseInt and Math are undefined,
     * which threw "v34 is not a function" on every change.
     */
    onViewSelect(ev) {
        const id = Number(ev.target.value);
        if (id) {
            this.loadView(id);
        }
    }

    onFilterNumber(field, ev) {
        const v = Number(ev.target.value);
        this.state.filters[field] = Number.isFinite(v) && ev.target.value !== "" ? v : null;
    }

    cancelBlockDraw() {
        this.state.drawing = false;
        this.state.draft = [];
        this.state.editingBlock = null;
    }

    backToMasterplan() {
        this.state.block = null;
        this.state.mode = "masterplan";
        this.state.view = null;
        this.state.zones = [];
        this.state.selected = null;
        this._saveNav();
    }

    backToProjects() {
        this.state.project = null;
        this.state.block = null;
        this.state.mode = null;
        this.state.view = null;
        this.state.unit = null;
        this.state.zones = [];
        this.state.units = [];
        // Deliberate exit: a reload now starts at the chooser again.
        try {
            window.sessionStorage.removeItem("vertikali.nav");
        } catch {
            // Nothing stored, nothing to clear.
        }
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
        // Grid, Grid+ and Properties are three readings of one dataset.
        if (this.isInventoryMode) {
            await this.loadGrid();
            await this.openFocusCard();
            this._saveNav();
            return;
        }
        const views = this.modeViews;
        let target = views[0];
        // With a deal's units marked, the Floors tab opens THEIR storey --
        // landing on the first floor of the list read as the marks vanishing.
        if (mode === "floor" && this.state.focusInfo.length) {
            const f = this.state.focusInfo[0];
            const want = f.vk_section || false;
            target = views.find(
                (v) => v.floor === f.vk_floor && (v.section || false) === want)
                || views.find((v) => v.floor === f.vk_floor)
                || target;
        }
        if (target) {
            await this.loadView(target.id);
            if (mode === "floor") {
                this.selectFocusZone();
            }
        }
        // The filter bar rides on the units dataset even on image views.
        if (!this.state.units.length) {
            await this.loadGrid();
        }
        await this.openFocusCard();
        this._saveNav();
    }

    /**
     * The marked unit's card greets the user on every view change: closing
     * it only clears the current screen, and the next tab opens it again.
     * Pick mode is exempt -- there the user is browsing, and a drawer
     * popping open on every tab would stand in the way.
     */
    async openFocusCard() {
        if (!this.state.focusUnits.size || this.pick) {
            return;
        }
        const unitId = this.focusUnitIds.find(
            (id) => this.state.focusUnits.has(id))
            || [...this.state.focusUnits][0];
        const row = this.state.unitById[unitId]
            || this.state.units.find((u) => u.id === unitId)
            || this.state.floorUnits.find((u) => u.id === unitId)
            || (await this.orm.searchRead(
                "product.template", [["id", "=", unitId]],
                ["default_code", "vk_floor", "vk_section", "vk_rooms",
                 "vk_area_total", "vk_area_balcony", "vk_orientation",
                 "list_price", "vk_price_sqm", "vk_state", "vk_handover",
                 "vk_condition_id", "vk_view_id", "vk_has_image",
                 "vk_layout_id", "write_date"]))[0];
        if (row) {
            this.openCard(row);
        }
    }

    /**
     * Remember where the user stands, so a reload lands on the same screen
     * instead of the project chooser. Saved on every navigation step.
     */
    _saveNav() {
        try {
            window.sessionStorage.setItem("vertikali.nav", JSON.stringify({
                projectId: this.state.project?.id || null,
                blockId: this.state.block?.id || null,
                mode: this.state.mode,
                viewId: this.state.view?.id || null,
            }));
        } catch {
            // Storage unavailable: reloads just start at the chooser.
        }
    }

    /** Put the user back on the screen the last reload interrupted. */
    async restoreNav() {
        let nav = null;
        try {
            nav = JSON.parse(
                window.sessionStorage.getItem("vertikali.nav") || "null");
        } catch {
            return;
        }
        if (!nav?.projectId) {
            return;
        }
        const project = this.state.projects.find((p) => p.id === nav.projectId);
        if (!project) {
            return;
        }
        this.state.project = project;
        this.state.block = this.state.blocks.find(
            (b) => b.id === nav.blockId) || null;
        this.refreshUnitTotal();
        if (!nav.mode) {
            return;
        }
        if (["grid", "gridplus", "properties"].includes(nav.mode)) {
            this.state.mode = nav.mode;
            await this.loadGrid();
            return;
        }
        if (nav.mode === "masterplan") {
            this.state.mode = "masterplan";
            return;
        }
        if (nav.viewId && this.state.views.some((v) => v.id === nav.viewId)) {
            this.state.mode = nav.mode;
            await this.loadView(nav.viewId);
            return;
        }
        await this.setMode(nav.mode);
    }

    /**
     * Does the zone survive the active filters? On a floor plan the zone is
     * one flat; a facade band passes while any unit on its storey does.
     * Zones without units (or with no active filter) always pass.
     */
    zoneMatchesFilters(zone) {
        if (!this.filterActive) {
            return true;
        }
        if (this.state.mode === "floor") {
            const unit = this.zoneUnit(zone);
            return !unit || this.matchesFilters(unit);
        }
        if (this.state.mode === "facade" && zone.floor) {
            return this.state.units.some(
                (u) => u.vk_floor === zone.floor
                    && (!zone.section || (u.vk_section || "") === zone.section)
                    && this.matchesFilters(u));
        }
        return true;
    }

    /** Select the marked unit's zone on the freshly loaded floor plan. */
    selectFocusZone() {
        if (!this.state.focusUnits.size) {
            return;
        }
        const zone = this.state.zones.find((z) => {
            const ids = z.product_tmpl_ids?.length
                ? z.product_tmpl_ids
                : (z.product_tmpl_id ? [z.product_tmpl_id[0]] : []);
            return ids.some((id) => this.state.focusUnits.has(id));
        });
        if (zone) {
            this.state.selected = zone;
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
                 "list_price", "vk_price_sqm", "vk_state", "vk_handover",
                 "vk_condition_id", "vk_view_id", "vk_has_image", "vk_layout_id", "write_date"],
                { order: "vk_floor desc, vk_section, default_code" }
            );
        } catch (e) {
            this.state.error = e.message || String(e);
        } finally {
            this.state.loading = false;
        }
    }

    /** Units passing the filters, for the list-shaped views. */
    get filteredUnits() {
        return this.state.units.filter((u) => this.matchesFilters(u));
    }

    /** Filtered units in the table's current sort order. */
    get sortedUnits() {
        const key = this.state.sortBy;
        const dir = this.state.sortAsc ? 1 : -1;
        return [...this.filteredUnits].sort((a, b) => {
            const x = a[key], y = b[key];
            if (typeof x === "number" && typeof y === "number") {
                return (x - y) * dir;
            }
            return String(x ?? "").localeCompare(
                String(y ?? ""), undefined, { numeric: true }) * dir;
        });
    }

    toggleSort(key) {
        if (this.state.sortBy === key) {
            this.state.sortAsc = !this.state.sortAsc;
        } else {
            this.state.sortBy = key;
            this.state.sortAsc = true;
        }
        this.state.page = 0;
    }

    // ------------------------------------------------ properties paging

    /** One page of the table: 126 rows scroll, 500 would crawl. */
    get pagedUnits() {
        const start = this.state.page * this.PAGE_SIZE;
        return this.sortedUnits.slice(start, start + this.PAGE_SIZE);
    }

    get pageInfo() {
        const total = this.sortedUnits.length;
        const start = this.state.page * this.PAGE_SIZE;
        return {
            start: total ? start + 1 : 0,
            end: Math.min(start + this.PAGE_SIZE, total),
            total,
            hasPrev: this.state.page > 0,
            hasNext: start + this.PAGE_SIZE < total,
        };
    }

    stepPage(delta) {
        const last = Math.max(
            0, Math.ceil(this.sortedUnits.length / this.PAGE_SIZE) - 1);
        this.state.page = Math.min(last, Math.max(0, this.state.page + delta));
    }

    /**
     * Columns of the Properties table.
     *
     * Defined here rather than as an array literal inside t-foreach: OWL
     * compiles the template to a function and a multi-line literal there
     * breaks it ("v36 is not a function").
     */
    get tableCols() {
        return [
            { key: "vk_state", label: "Status" },
            { key: "default_code", label: "Unit" },
            { key: "vk_rooms", label: "Layout" },
            { key: "vk_building", label: "Building" },
            { key: "vk_section", label: "Section" },
            { key: "vk_floor", label: "Floor", num: true },
            { key: "vk_area_total", label: "Area, m²", num: true },
            { key: "vk_price_sqm", label: "Price / m²", num: true },
            { key: "list_price", label: "Price", num: true },
        ];
    }

    /**
     * Grid+ groups all units by floor, high to low. Filtered-out units fade
     * like the grid's cells rather than disappearing -- vanishing rows made
     * the floors look half-built.
     */
    get plusRows() {
        const byFloor = new Map();
        for (const raw of this.state.units) {
            const u = { ...raw, dimmed: !this.matchesFilters(raw) };
            if (!byFloor.has(u.vk_floor)) {
                byFloor.set(u.vk_floor, []);
            }
            byFloor.get(u.vk_floor).push(u);
        }
        return [...byFloor.entries()]
            .sort((a, b) => b[0] - a[0])
            .map(([floor, units]) => ({
                floor,
                units: units.sort((a, b) => String(a.default_code)
                    .localeCompare(String(b.default_code), undefined, { numeric: true })),
            }));
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

    /** Orientations present in the loaded units, for the filter chips. */
    get orientOptions() {
        return [...new Set(this.state.units.map((u) => u.vk_orientation).filter(Boolean))]
            .sort();
    }

    /** Distinct many2one values on the loaded units, as {id, name} chips. */
    _m2oOptions(field) {
        const seen = new Map();
        for (const u of this.state.units) {
            const v = u[field];
            if (v && !seen.has(v[0])) {
                seen.set(v[0], v[1]);
            }
        }
        return [...seen.entries()]
            .map(([id, name]) => ({ id, name }))
            .sort((a, b) => a.name.localeCompare(b.name));
    }

    /** Conditions present in the loaded units, for the filter chips. */
    get condOptions() {
        return this._m2oOptions("vk_condition_id");
    }

    /** Window views present in the loaded units, for the filter chips. */
    get viewOptions() {
        return this._m2oOptions("vk_view_id");
    }

    matchesFilters(u) {
        const f = this.state.filters;
        if (f.rooms.length && !f.rooms.includes(u.vk_rooms)) {
            return false;
        }
        if (f.status.length && !f.status.includes(u.vk_state)) {
            return false;
        }
        if (f.orient.length && !f.orient.includes(u.vk_orientation)) {
            return false;
        }
        if (f.cond.length && !f.cond.includes(u.vk_condition_id?.[0])) {
            return false;
        }
        if (f.vview.length && !f.vview.includes(u.vk_view_id?.[0])) {
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
        this.state.page = 0;
        const list = this.state.filters[kind];
        const i = list.indexOf(value);
        if (i >= 0) {
            list.splice(i, 1);
        } else {
            list.push(value);
        }
    }

    get filterGroups() {
        return FILTER_GROUPS;
    }

    /** Gear toggle: hiding a group also drops its active filters, so a
     *  hidden group can never keep invisibly narrowing the list. */
    toggleFilterVis(key) {
        const vis = this.state.filterVis;
        vis[key] = !vis[key];
        if (!vis[key]) {
            if (key === "layout") {
                this.state.filters.rooms = [];
            } else if (key === "area") {
                this.state.filters.areaMin = null;
                this.state.filters.areaMax = null;
            } else if (key === "price") {
                this.state.filters.priceMax = null;
            } else if (this.state.filters[key]) {
                this.state.filters[key] = [];
            }
        }
        try {
            window.localStorage.setItem(FILTER_VIS_KEY, JSON.stringify(vis));
        } catch {
            // Private mode: the choice just does not survive the session.
        }
    }

    clearFilters() {
        this.state.page = 0;
        this.state.filters.rooms = [];
        this.state.filters.status = [];
        this.state.filters.orient = [];
        this.state.filters.cond = [];
        this.state.filters.vview = [];
        this.state.filters.areaMin = null;
        this.state.filters.areaMax = null;
        this.state.filters.priceMax = null;
    }

    get filterActive() {
        const f = this.state.filters;
        return !!(f.rooms.length || f.status.length || f.orient.length
                  || f.cond.length || f.vview.length
                  || f.areaMin || f.areaMax || f.priceMax);
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

    /**
     * Hover card over a grid cell: what the unit is and what it costs, the
     * way the reference shows it. Anchored to the cell in page coordinates,
     * since the grid scrolls.
     */
    showCellTip(unit, ev) {
        const r = ev.currentTarget.getBoundingClientRect();
        this.state.cellTip = {
            unit,
            x: r.left + r.width / 2,
            y: r.top,
        };
    }

    hideCellTip() {
        this.state.cellTip = null;
    }

    /** Open the plan for a grid row, so a floor is one click from the table. */
    async openFloorFromGrid(floor) {
        const plan = this.floorViews.find((v) => v.floor === floor);
        if (!plan) {
            this.notification.add(
                `No floor plan for floor ${floor} yet.`, { type: "warning" });
            return;
        }
        this.state.mode = "floor";
        await this.loadView(plan.id);
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

    /** Open the full unit card (the plan + specs screen). */
    async openCard(unit) {
        if (!unit) {
            return;
        }
        this.state.card = unit;
        this.state.slide = 0;
        this.state.gallery = [];
        this.state.cardLeads = [];
        this.state.cardOrders = [];
        try {
            // The product image plus any extra images: a unit usually has a
            // layout, a furnished view and a couple of renders.
            // Read the whole Unit tab, so the card shows the record rather
            // than whatever the list view happened to carry.
            // No image field in this read: the gallery addresses every picture
            // by URL so the browser streams and caches them, and a card with a
            // dozen renders no longer drags megabytes through the RPC.
            const [rec] = await this.orm.read(
                "product.template", [unit.id],
                ["vk_has_image", "write_date", "product_variant_id",
                 "vk_orientation", "vk_rooms_detail",
                 "vk_condition_id", "vk_view_id", "vk_handover", "vk_section", "vk_building",
                 "vk_rooms", "vk_floor", "vk_state", "vk_area_total",
                 "vk_area_living", "vk_area_balcony", "vk_price_sqm",
                 "list_price", "vk_layout_id"]);
            Object.assign(this.state.card, rec);

            // A shared layout supplies the drawing when the unit has none of
            // its own -- a typical flat repeats across the tower, so its plan
            // is uploaded once rather than onto each unit.
            const [layoutId] = rec.vk_layout_id || [];
            let layout = null;
            if (layoutId) {
                [layout] = await this.orm.read(
                    "vertikali.layout", [layoutId],
                    ["name", "has_image", "write_date"]);
            }

            const domain = layoutId
                ? ["|", ["product_tmpl_id", "=", unit.id], ["layout_id", "=", layoutId]]
                : [["product_tmpl_id", "=", unit.id]];
            const extra = await this.orm.searchRead(
                "vertikali.unit.image", domain, ["name", "write_date"],
                { order: "sequence, id", limit: 20 });

            const shots = [];
            if (rec.vk_has_image) {
                shots.push({
                    id: "own", name: "Layout",
                    src: this.imgUrl("product.template", unit.id, "image_1920",
                                     rec.write_date),
                });
            } else if (layout?.has_image) {
                shots.push({
                    id: "layout", name: layout.name,
                    src: this.imgUrl("vertikali.layout", layoutId, "image",
                                     layout.write_date),
                });
            }
            for (const img of extra) {
                shots.push({
                    id: img.id, name: img.name,
                    src: this.imgUrl("vertikali.unit.image", img.id, "image",
                                     img.write_date),
                });
            }
            this.state.gallery = shots;
            this.state.card.layoutName = layout?.name || null;

            // Opportunities and orders already tied to this unit, so the card
            // answers "who else is on it". Either read fails quietly for a
            // user whose rights do not reach that model -- the section then
            // simply is not there.
            try {
                this.state.cardLeads = await this.orm.searchRead(
                    "crm.lead", [["vk_unit_ids", "in", [unit.id]]],
                    ["name", "stage_id", "partner_id"],
                    { order: "id desc", limit: 10 });
            } catch {
                this.state.cardLeads = [];
            }
            try {
                this.state.cardOrders = await this.orm.searchRead(
                    "sale.order",
                    [["order_line.product_id.product_tmpl_id", "=", unit.id],
                     ["state", "!=", "cancel"]],
                    ["name", "partner_id", "state", "vk_stage"],
                    { order: "id desc", limit: 10 });
            } catch {
                this.state.cardOrders = [];
            }
        } catch (e) {
            this.state.gallery = [];
        }
    }

    /** Streamed image URL. write_date busts the cache when the file changes. */
    imgUrl(model, id, field, writeDate, size = 1920) {
        const stamp = encodeURIComponent(writeDate || "");
        return `/web/image/${model}/${id}/${field}/${size}x${size}?unique=${stamp}`;
    }

    /**
     * Small plan thumbnail for a unit row: its own drawing, else the shared
     * layout's. Null when there is neither, so the row shows a blank square
     * rather than Odoo's grey placeholder.
     */
    unitThumb(u, size = 256) {
        if (!u) {
            return null;
        }
        if (u.vk_has_image) {
            return this.imgUrl("product.template", u.id, "image_1920",
                               u.write_date, size);
        }
        const [layoutId] = u.vk_layout_id || [];
        if (layoutId) {
            return this.imgUrl("vertikali.layout", layoutId, "image",
                               u.write_date, size);
        }
        return null;
    }

    /**
     * Floors that have a band on the open facade, top storey first — the
     * facade's answer to the floor view's stepper rail. One entry per floor:
     * a split storey keeps its per-section bands on the image itself.
     */
    get facadeFloors() {
        const seen = new Map();
        for (const z of this.state.zones) {
            if (z.floor && !seen.has(z.floor)) {
                seen.set(z.floor, z);
            }
        }
        return [...seen.entries()]
            .sort((a, b) => b[0] - a[0])
            .map(([floor, zone]) => ({ floor, zone }));
    }

    /** Rail click: same as clicking the band itself. */
    selectFacadeFloor(entry) {
        this.onZoneClick(entry.zone);
    }

    /** Status counts for the open floor, mirroring the facade band's line. */
    get floorStats() {
        const s = { available: 0, reserved: 0, sold: 0 };
        for (const u of this.state.floorUnits) {
            if (s[u.vk_state] !== undefined) {
                s[u.vk_state] += 1;
            }
        }
        return s;
    }

    get slideSrc() {
        return this.state.gallery[this.state.slide]?.src || null;
    }

    get slideName() {
        return this.state.gallery[this.state.slide]?.name || "";
    }

    goSlide(i) {
        const n = this.state.gallery.length;
        if (n) {
            this.state.slide = (i + n) % n;
        }
    }

    /** Condition is a configurable option now, so its name is the label. */
    get conditionLabel() {
        return this.state.card?.vk_condition_id?.[1] || null;
    }

    /** Compass label for a unit's aspect. */
    orientLabel(v) {
        const map = {
            n: "North", ne: "North-East", e: "East", se: "South-East",
            s: "South", sw: "South-West", w: "West", nw: "North-West",
        };
        return map[v] || v || null;
    }

    get orientationLabel() {
        return this.orientLabel(this.state.card?.vk_orientation);
    }

    /** Needle angle, clockwise from north. */
    get orientationDeg() {
        const deg = {
            n: 0, ne: 45, e: 90, se: 135, s: 180, sw: 225, w: 270, nw: 315,
        };
        return deg[this.state.card?.vk_orientation] ?? 0;
    }

    closeCard() {
        this.state.card = null;
        this.state.zoom = false;
    }

    openZoom() {
        if (this.slideSrc) {
            this.state.zoom = true;
        }
    }

    closeZoom() {
        this.state.zoom = false;
    }

    /** Room areas parsed from the free-text field, for the card breakdown. */
    get cardRooms() {
        const raw = this.state.card?.vk_rooms_detail || "";
        return raw.split("\n").map((line) => {
            const t = line.trim();
            if (!t) {
                return null;
            }
            const m = t.match(/^(.*?)[\s]+([\d.,]+)$/);
            return m
                ? { label: m[1], area: m[2] }
                : { label: t, area: null };
        }).filter(Boolean);
    }

    /**
     * Where the card's unit sits among the others on its floor -- the small
     * map at the bottom of the panel. Ordered by code so the strip is stable.
     */
    get floorStrip() {
        const card = this.state.card;
        if (!card) {
            return [];
        }
        const source = this.state.floorUnits.length ? this.state.floorUnits : this.state.units;
        return source
            .filter((u) => u.vk_floor === card.vk_floor)
            .sort((a, b) => String(a.default_code).localeCompare(String(b.default_code)))
            .map((u) => ({ ...u, current: u.id === card.id }));
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

    // -------------------------------------------------- opportunity links

    /**
     * Deep-link from an opportunity: open the first attached unit's floor
     * plan and select its zone; every attached unit's zone gets the focus
     * outline. Falls back to the grid card when no plan carries the unit.
     */
    async openFocusUnits() {
        const unitId = this.focusUnitIds[0];
        // All of them, not just the first: the facade and masterplan
        // outlines need every attached unit's floor and building.
        const infos = await this.orm.read(
            "product.template", this.focusUnitIds,
            ["vk_building", "vk_floor", "vk_section", "default_code"]);
        this.state.focusInfo = infos;
        const unit = infos.find((u) => u.id === unitId) || infos[0];
        if (!unit) {
            return;
        }
        const project = this.state.projects.find(
            (p) => p.building === unit.vk_building) || this.state.projects[0];
        if (!project) {
            return;
        }
        this.state.project = project;
        this.state.block = this.state.blocks.find(
            (b) => b.project_id?.[0] === project.id
                && b.code === unit.vk_building)
            || this.state.blocks.find((b) => b.code === unit.vk_building)
            || null;
        this.refreshUnitTotal();

        // Land on the best view the project actually has switched on --
        // a step the project disabled must not come back through a deep
        // link. Floor plan first, then facade, then masterplan, then grid.
        if (project.use_floorplan) {
            const want = unit.vk_section || false;
            const floors = this.state.views.filter(
                (v) => v.view_type === "floor" && v.floor === unit.vk_floor
                    && (!v.building || v.building === unit.vk_building));
            const plan = floors.find((v) => (v.section || false) === want)
                || floors.find((v) => !v.section) || floors[0];
            if (plan) {
                this.state.mode = "floor";
                await this.loadView(plan.id);
                this.selectFocusZone();
                if (!this.state.units.length) {
                    await this.loadGrid();
                }
                // The card opens along with the plan: arriving from a lead
                // or an order, the unit's full story is the trip's point.
                await this.openFocusCard();
                return;
            }
        }
        if (project.use_facade) {
            const facadeId = this.state.block?.facade_view_id?.[0]
                || this.state.views.find(
                    (v) => v.view_type === "facade"
                        && (!v.building || v.building === unit.vk_building))?.id;
            if (facadeId) {
                this.state.mode = "facade";
                await this.loadView(facadeId);
                if (!this.state.units.length) {
                    await this.loadGrid();
                }
                await this.openFocusCard();
                return;
            }
        }
        if (project.use_masterplan) {
            this.state.mode = "masterplan";
            this.state.view = null;
            this.state.zones = [];
            await this.openFocusCard();
            return;
        }
        // Grid: always available as the last resort, and the only stop
        // when it is the project's single enabled step.
        this.state.mode = "grid";
        await this.loadGrid();
        await this.openFocusCard();
    }

    /**
     * A zone stands for (or covers) a unit the deal is about. On a floor
     * plan zones ARE units, so only an id match counts; a facade band
     * covers a whole storey, so it lights up when any focused unit lives
     * on its floor (and section, where the storey is split).
     */
    isFocusZone(zone) {
        if (!this.state.focusUnits.size) {
            return false;
        }
        const ids = zone.product_tmpl_ids?.length
            ? zone.product_tmpl_ids
            : (zone.product_tmpl_id ? [zone.product_tmpl_id[0]] : []);
        if (ids.some((id) => this.state.focusUnits.has(id))) {
            return true;
        }
        if (this.state.mode === "facade" && zone.floor) {
            return this.state.focusInfo.some(
                (u) => u.vk_floor === zone.floor
                    && (!zone.section || (u.vk_section || "") === zone.section));
        }
        return false;
    }

    /** A masterplan block holding any of the deal's units. */
    isFocusBlock(block) {
        return !!this.state.focusInfo.length
            && this.state.focusInfo.some((u) => u.vk_building === block.code);
    }

    /** Focused units light their grid cells and inventory rows too. */
    isFocusUnit(unit) {
        return this.state.focusUnits.has(unit.id);
    }

    /**
     * Pick mode: put this unit on the target and keep browsing. A lead
     * takes it into its unit list; a quotation takes it as an order line.
     */
    async attachToPick(unit) {
        if (unit.vk_state !== "available") {
            this.notification.add(
                `${unit.default_code} is reserved or sold -- it cannot be attached.`,
                { type: "warning" });
            return;
        }
        try {
            if (this.pick.model === "sale.order") {
                const [variantId] = unit.product_variant_id || [];
                if (!variantId) {
                    throw new Error("This unit has no sellable variant.");
                }
                await this.orm.create("sale.order.line", [{
                    order_id: this.pick.id,
                    product_id: variantId,
                    product_uom_qty: 1,
                    price_unit: unit.list_price,
                }]);
            } else {
                await this.orm.write("crm.lead", [this.pick.id],
                    { vk_unit_ids: [[4, unit.id]] });
            }
            this.state.focusUnits.add(unit.id);
            this.state.focusInfo.push({
                id: unit.id,
                vk_floor: unit.vk_floor,
                vk_building: unit.vk_building,
                vk_section: unit.vk_section,
                default_code: unit.default_code,
            });
            this.notification.add(
                `${unit.default_code} attached to ${this.pick.name}.`,
                { type: "success" });
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    /** Back to the record the selector was opened from (lead or order). */
    backToOrigin() {
        const model = this.origin?.model || this.pick?.model;
        const resId = this.origin?.id || this.pick?.id;
        if (!model || !resId) {
            return;
        }
        // The session is over; a later menu launch starts clean.
        try {
            window.sessionStorage.removeItem("vertikali.ctx");
        } catch {
            // Nothing stashed, nothing lost.
        }
        this.action.doAction({
            type: "ir.actions.act_window",
            res_model: model,
            res_id: resId,
            views: [[false, "form"]],
            target: "current",
        });
    }

    /**
     * One click from the card to a pipeline entry: the opportunity is
     * created with the unit already attached, then opened for the contact
     * details. Named after the unit so the board reads at a glance.
     */
    async createOpportunity(unit) {
        try {
            const name = `${unit.default_code} — ${this.state.project?.name || "unit"}`;
            const [leadId] = await this.orm.create("crm.lead", [{
                name,
                type: "opportunity",
                vk_unit_ids: [[4, unit.id]],
            }]);
            this.action.doAction({
                type: "ir.actions.act_window",
                res_model: "crm.lead",
                res_id: leadId,
                views: [[false, "form"]],
                target: "current",
            });
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    /**
     * Straight to a quotation with the unit already on it. Opened as a new
     * form rather than created silently: an order needs a customer, and
     * that is the one thing the card cannot know.
     */
    createQuotation(unit) {
        const [variantId] = unit.product_variant_id || [];
        if (!variantId) {
            this.notification.add("This unit has no sellable variant.",
                { type: "danger" });
            return;
        }
        this.action.doAction({
            type: "ir.actions.act_window",
            res_model: "sale.order",
            views: [[false, "form"]],
            target: "current",
            context: {
                default_order_line: [[0, 0, {
                    product_id: variantId,
                    product_uom_qty: 1,
                    price_unit: unit.list_price,
                }]],
            },
        });
    }

    /** An order row on the card opens the order itself. */
    openOrder(order) {
        this.action.doAction({
            type: "ir.actions.act_window",
            res_model: "sale.order",
            res_id: order.id,
            views: [[false, "form"]],
            target: "current",
        });
    }

    /** A lead row on the card opens the pipeline record itself. */
    openLead(lead) {
        this.action.doAction({
            type: "ir.actions.act_window",
            res_model: "crm.lead",
            res_id: lead.id,
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
                ["name", "view_type", "building", "floor", "section",
                 "has_image", "write_date"]
            );
            this.state.view = view;

            const zones = await this.orm.searchRead(
                "vertikali.polygon", [["view_id", "=", viewId]],
                ["name", "floor", "section", "points", "target_view_id",
                 "product_tmpl_id", "product_tmpl_ids",
                 "unit_count", "available_count", "reserved_count",
                 "sold_count", "price_from"],
                { order: "sequence, id" }
            );
            this.state.zones = zones.map((z) => ({ ...z, pts: this.parsePoints(z.points) }));

            // On a floor plan the zones stand for units, so pull their status
            // and price: the plan has to show what is sold before it is useful.
            if (view.view_type === "floor") {
                await this.loadFloorUnits(view.floor);
            }
        } catch (e) {
            this.state.error = e.message || String(e);
        } finally {
            this.state.loading = false;
        }
        this._saveNav();
    }

    /** Units on one floor, keyed by template id for the plan overlay. */
    async loadFloorUnits(floor) {
        const domain = [["vk_is_unit", "=", true], ["vk_floor", "=", floor]];
        const building = this.state.block?.code || this.state.project?.building;
        if (building) {
            domain.push(["vk_building", "=", building]);
        }
        const units = await this.orm.searchRead(
            "product.template", domain,
            ["default_code", "vk_floor", "vk_section", "vk_rooms", "vk_area_total",
             "vk_area_balcony", "vk_orientation", "list_price", "vk_price_sqm",
             "vk_state", "vk_handover", "vk_rooms_detail", "vk_condition_id", "vk_view_id",
             "vk_has_image", "vk_layout_id", "write_date"],
            { order: "default_code" }
        );
        this.state.floorUnits = units;
        this.state.unitById = Object.fromEntries(units.map((u) => [u.id, u]));
    }

    /**
     * Units behind the selected facade band, with that floor's plan.
     *
     * Prefers the units explicitly attached to the zone; falls back to the
     * floor (and section, where the facade is split into wings) so a band
     * still previews its storey before anyone has attached anything.
     */
    async loadZoneUnits(zone) {
        this.state.zoneUnits = [];
        this.state.zonePlan = null;
        // On a floor plan the zone stands for a flat on the open storey, so
        // the floor comes from the view rather than the zone itself.
        const floor = zone?.floor || this.state.view?.floor;
        if (!zone || !floor) {
            this.state.floorPick = [];
            return;
        }
        // Everything on the storey, so the editor can tick units the section
        // filter would hide -- picking by hand is the fallback when the units
        // carry no section at all. Only refetched when the floor changes, so
        // the list does not blink on every tick.
        if (this.state.floorPick[0]?.vk_floor !== floor) {
            this.unitsOnFloor(floor)
                .then((rows) => { this.state.floorPick = rows; })
                .catch(() => { this.state.floorPick = []; });
        }
        try {
            const fields = [
                "default_code", "vk_floor", "vk_section", "vk_rooms",
                "vk_area_total", "list_price", "vk_price_sqm", "vk_state",
                "vk_area_balcony", "vk_handover", "vk_rooms_detail",
                "vk_condition_id", "vk_view_id", "vk_has_image", "vk_layout_id",
                "write_date",
            ];
            const ids = zone.product_tmpl_ids || [];
            if (ids.length) {
                this.state.zoneUnits = await this.orm.read(
                    "product.template", ids, fields);
            } else {
                const domain = [
                    ["vk_is_unit", "=", true], ["vk_floor", "=", floor],
                ];
                if (zone.section) {
                    domain.push(["vk_section", "=", zone.section]);
                }
                const building = this.state.block?.code || this.state.view?.building;
                if (building) {
                    domain.push(["vk_building", "=", building]);
                }
                this.state.zoneUnits = await this.orm.searchRead(
                    "product.template", domain, fields, { order: "default_code" });
            }

            // The plan for this exact band: floor *and* section. floorList
            // keeps one entry per storey, so it would hand back whichever
            // section happened to come first.
            const want = zone.section || false;
            const plan = this.floorViews.find(
                (v) => v.floor === floor && (v.section || false) === want)
                || this.floorViews.find(
                    (v) => v.floor === floor && !v.section);
            if (plan) {
                const [rec] = await this.orm.read(
                    "vertikali.view", [plan.id],
                    ["name", "has_image", "write_date"]);
                this.state.zonePlan = rec;
            }
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    /** Attach every unit on this zone's floor/section in one go. */
    async fillZoneUnits(zone) {
        if (!zone?.floor) {
            this.notification.add(
                "Give the zone a floor first.", { type: "warning" });
            return;
        }
        try {
            await this.orm.call(
                "vertikali.polygon", "action_fill_units_from_floor", [[zone.id]]);
            const [rec] = await this.orm.read(
                "vertikali.polygon", [zone.id], ["product_tmpl_ids"]);
            zone.product_tmpl_ids = rec.product_tmpl_ids;
            await this.loadZoneUnits(zone);

            if (rec.product_tmpl_ids.length) {
                this.notification.add(
                    `${rec.product_tmpl_ids.length} units attached.`,
                    { type: "success" });
                return;
            }

            // Nothing matched. Almost always the zone asks for a section the
            // units do not carry, so say that rather than reporting a bare
            // zero -- and offer to stamp the section onto the floor's units.
            if (zone.section) {
                const onFloor = await this.unitsOnFloor(zone.floor);
                if (onFloor.length) {
                    const ok = window.confirm(
                        `No unit on floor ${zone.floor} is marked section `
                        + `"${zone.section}".\n\n`
                        + `Set section "${zone.section}" on all ${onFloor.length} `
                        + `units of this floor and attach them?`);
                    if (ok) {
                        await this.orm.write(
                            "product.template", onFloor.map((u) => u.id),
                            { vk_section: zone.section });
                        await this.fillZoneUnits(zone);
                        return;
                    }
                    this.notification.add(
                        `Set the section on the units first, or clear it on `
                        + `the zone to take the whole floor.`,
                        { type: "warning" });
                    return;
                }
            }
            this.notification.add(
                `No units found on floor ${zone.floor}.`, { type: "warning" });
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    /** Units on a floor of the current building, ignoring section. */
    async unitsOnFloor(floor) {
        const domain = [["vk_is_unit", "=", true], ["vk_floor", "=", floor]];
        const building = this.state.block?.code || this.state.view?.building;
        if (building) {
            domain.push(["vk_building", "=", building]);
        }
        return this.orm.searchRead(
            "product.template", domain,
            ["default_code", "vk_section", "vk_floor"],
            { order: "default_code" });
    }

    /** Add or remove one unit from the selected zone. */
    async toggleZoneUnit(zone, unit) {
        const ids = [...(zone.product_tmpl_ids || [])];
        const i = ids.indexOf(unit.id);
        const adding = i < 0;
        if (adding) {
            ids.push(unit.id);
        } else {
            ids.splice(i, 1);
        }
        try {
            await this.orm.write("vertikali.polygon", [zone.id], {
                product_tmpl_ids: [[6, 0, ids]],
            });
            zone.product_tmpl_ids = ids;

            // Stamp the band's section onto the unit, so the two agree and a
            // later fill-from-floor picks it up on its own.
            if (adding && zone.section && unit.vk_section !== zone.section) {
                await this.orm.write("product.template", [unit.id], {
                    vk_section: zone.section,
                });
                unit.vk_section = zone.section;
            }
            await this.loadZoneUnits(zone);
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    zoneHasUnit(zone, unit) {
        return (zone?.product_tmpl_ids || []).includes(unit.id);
    }

    /** Save the zone's section, which narrows which units it covers. */
    async setZoneSection(zone, value) {
        const section = (value || "").trim() || false;
        try {
            await this.orm.write("vertikali.polygon", [zone.id], { section });
            zone.section = section;
            await this.loadZoneUnits(zone);
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    /**
     * Status split for the open band. Counts the units actually shown, so a
     * band that has none attached still reports its floor honestly rather
     * than three zeros.
     */
    get zoneStats() {
        const n = (s) => this.state.zoneUnits.filter((u) => u.vk_state === s).length;
        return {
            total: this.state.zoneUnits.length,
            available: n("available"),
            reserved: n("reserved"),
            sold: n("sold"),
        };
    }

    get zonePlanSrc() {
        const p = this.state.zonePlan;
        if (!p || !p.has_image) {
            return null;
        }
        const stamp = encodeURIComponent(p.write_date || "");
        return `/web/image/vertikali.view/${p.id}/image/1024x1024?unique=${stamp}`;
    }

    /** The unit a floor-plan zone stands for, if it is linked. */
    /**
     * The flat a floor-plan zone stands for.
     *
     * Checks product_tmpl_ids first: zones are attached through the many2many
     * now, and looking only at the old single link meant a drawn-and-linked
     * zone opened nothing.
     */
    zoneUnit(zone) {
        // Only on a floor plan does a zone stand for one flat. A facade band
        // also carries attached units, and unitById keeps the last visited
        // floor's rows -- resolving there painted a stray unit pin (and its
        // status colours) onto the facade.
        if (this.state.mode !== "floor") {
            return null;
        }
        const id = zone.product_tmpl_ids?.[0] || zone.product_tmpl_id?.[0];
        if (!id) {
            return null;
        }
        return this.state.unitById[id]
            || this.state.floorUnits.find((u) => u.id === id)
            || null;
    }

    /** Every floor plan of the current project/block. */
    get floorViews() {
        return this.state.views.filter((v) => v.view_type === "floor"
            && (!this.state.project || v.project_id?.[0] === this.state.project.id)
            && (!this.state.block || !v.building || v.building === this.state.block.code));
    }

    /**
     * Floors for the stepper, high to low -- one entry per storey even when
     * the storey has several section plans, so the stepper lists floors and
     * the section switcher handles the rest.
     */
    get floorList() {
        const seen = new Set();
        const out = [];
        for (const v of this.floorViews.sort((a, b) => b.floor - a.floor)) {
            if (seen.has(v.floor)) {
                continue;
            }
            seen.add(v.floor);
            out.push(v);
        }
        return out;
    }

    /**
     * The storeys shown in the stepper: the current one and two either side.
     *
     * Filtered here rather than with Math.abs() in the template -- OWL
     * evaluates template expressions in a restricted scope where Math is not
     * defined, which threw "v36 is not a function" on every floor change.
     */
    get stepperFloors() {
        const cur = this.state.view?.floor;
        if (cur === undefined || cur === null) {
            return [];
        }
        return this.floorList.filter((v) => {
            const d = v.floor - cur;
            return (d < 0 ? -d : d) <= 2;
        });
    }

    /** Section plans of the open storey, for the switcher along the bottom. */
    get floorSections() {
        const floor = this.state.view?.floor;
        if (!floor) {
            return [];
        }
        const rows = this.floorViews
            .filter((v) => v.floor === floor)
            .sort((a, b) => String(a.section || "").localeCompare(
                String(b.section || ""), undefined, { numeric: true }));
        // A lone plan is not worth a switcher.
        return rows.length > 1 ? rows : [];
    }

    /** Move up or down a storey without leaving the plan. */
    async stepFloor(delta) {
        const list = this.floorList;
        const cur = this.state.view;
        const i = list.findIndex((v) => v.floor === cur?.floor);
        const next = list[i - delta];   // list is high-to-low, so invert
        if (!next) {
            return;
        }
        // Stay in the same section across storeys where that section exists,
        // so stepping up a wing does not jump to a different one.
        const same = this.floorViews.find(
            (v) => v.floor === next.floor && (v.section || false) === (cur?.section || false));
        await this.loadView((same || next).id);
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

    /**
     * Facade/floor render as a streamed URL.
     *
     * Same reasoning as the project cover: reading the base64 through the ORM
     * held up the first paint by the whole size of the render, and the browser
     * could not cache it between visits.
     */
    get imageSrc() {
        const v = this.state.view;
        if (!v || !v.has_image) {
            return null;
        }
        const stamp = encodeURIComponent(v.write_date || "");
        return `/web/image/vertikali.view/${v.id}/image/1920x1920?unique=${stamp}`;
    }

    /**
     * Project cover as a URL rather than inline base64.
     *
     * The browser then streams and caches it like any other image, instead of
     * the whole thing riding along in the RPC payload before the page can
     * paint. write_date busts the cache when the cover changes.
     */
    coverSrc(project, size = 1920) {
        if (!project) {
            return null;
        }
        const stamp = encodeURIComponent(project.write_date || "");
        return `/web/image/vertikali.project/${project.id}/image/${size}x${size}?unique=${stamp}`;
    }

    /** Small version for the chooser cards. */
    coverThumb(project) {
        return this.coverSrc(project, 512);
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
     * The overlay is aligned by CSS -- the image and the SVG share one grid
     * cell -- so nothing needs measuring. Kept as a no-op hook because the
     * image still reports when it has loaded.
     */
    onImageLoad() {}

    /**
     * Pointer position as a 0..1 coordinate on the image.
     *
     * The frame is exactly the picture -- the image sizes it and the SVG fills
     * it -- so one rect serves both the click and the drawing, with no
     * letterbox to back out and nothing to fall out of sync.
     */
    toNorm(ev) {
        const frame = this.frameRef.el;
        if (!frame) {
            return [0, 0];
        }
        const r = frame.getBoundingClientRect();
        if (!r.width || !r.height) {
            return [0, 0];
        }
        const clamp = (v) => Math.min(1, Math.max(0, Math.round(v * 10000) / 10000));
        return [
            clamp((ev.clientX - r.left) / r.width),
            clamp((ev.clientY - r.top) / r.height),
        ];
    }

    // -------------------------------------------------------------- select

    onZoneClick(zone) {
        if (this.state.drawing) {
            return;
        }
        // A zone the filters ruled out is faded and inert outside editing.
        if (!this.state.editing && !this.zoneMatchesFilters(zone)) {
            return;
        }
        this.state.selected = zone;
        // Show what the band sells, plus that floor's plan, without leaving
        // the facade -- the point of a facade band is to preview the storey.
        // Entering the plan is a separate, deliberate step ("Open floor plan"
        // in the panel); drilling in on this same click meant the preview was
        // never visible.
        this.loadZoneUnits(zone);
        if (this.state.editing) {
            return;
        }
        // On a floor plan a zone *is* a flat, so it opens its card. A facade
        // band covers a whole storey and only previews it in the panel.
        if (this.state.mode === "floor") {
            const unit = this.zoneUnit(zone);
            if (unit) {
                this.openCard(unit);
            }
        }
    }

    /** Enter the floor plan behind the selected band. */
    openZonePlan(zone) {
        if (zone?.target_view_id) {
            this.state.mode = "floor";
            this.loadView(zone.target_view_id[0]);
        } else if (this.state.zonePlan) {
            this.state.mode = "floor";
            this.loadView(this.state.zonePlan.id);
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
    }

    startDraw() {
        this.state.drawing = true;
        this.state.draft = [];
        this.state.selected = null;
    }

    onStageClick(ev) {
        if (!this.state.drawing) {
            return;
        }
        // Blocks are drawn on the masterplan without entering zone-edit mode.
        const blockMode = !!this.state.editingBlock;
        if (!blockMode && !this.state.editing) {
            return;
        }
        const p = this.toNorm(ev);
        // Closing on the first point finishes the shape.
        if (this.state.draft.length >= 3) {
            const [fx, fy] = this.state.draft[0];
            if (Math.hypot(p[0] - fx, p[1] - fy) < 0.015) {
                if (blockMode) {
                    this.finishBlockDraw();
                } else {
                    this.finishDraw();
                }
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
        await this.duplicateBy(1);
    }

    async duplicateUp() {
        await this.duplicateBy(-1);
    }

    /** Copy the selected zone one band up (-1) or down (+1). */
    async duplicateBy(direction) {
        const src = this.state.selected;
        if (!src) {
            this.notification.add("Select a zone to copy first.", { type: "warning" });
            return;
        }
        const step = this.bandStep(src) * direction;
        const pts = src.pts.map(([x, y]) => [
            x,
            Math.min(1, Math.max(0, Math.round((y + step) * 10000) / 10000)),
        ]);
        const ys = pts.map((p) => p[1]);
        if (Math.max(...ys) <= 0 || Math.min(...ys) >= 1) {
            this.notification.add("No room left in that direction.", { type: "warning" });
            return;
        }
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

    /**
     * Point a facade zone at a floor. A zone with no floor leads nowhere, so
     * this has to be reachable while drawing rather than only in a form.
     */
    async assignFloor(zone, floor) {
        const n = parseInt(floor, 10);
        const vals = { floor: Number.isNaN(n) ? false : n, name: `Floor ${n}` };
        // Wire it to that floor's plan too, so the drill-down works at once.
        const target = this.floorList.find((v) => v.floor === n);
        vals.target_view_id = target ? target.id : false;
        try {
            await this.orm.write("vertikali.polygon", [zone.id], vals);
            zone.floor = vals.floor;
            zone.name = vals.name;
            zone.target_view_id = target ? [target.id, target.name] : false;
        } catch (e) {
            this.notification.add(e.message || String(e), { type: "danger" });
        }
    }

    /**
     * Number the zones top to bottom from a starting storey. Tracing 21 bands
     * and then setting each floor by hand is the slow part, not the drawing.
     */
    async autoNumberZones() {
        const zones = [...this.state.zones];
        if (!zones.length) {
            return;
        }
        const start = window.prompt(
            "Top zone is which floor? (numbering runs downwards)",
            String(this.state.block?.floors || zones.length + 1)
        );
        if (!start) {
            return;
        }
        let floor = parseInt(start, 10);
        if (Number.isNaN(floor)) {
            return;
        }
        // Top of the image first, so the order matches the building.
        zones.sort((a, b) => {
            const ay = Math.min(...a.pts.map((p) => p[1]));
            const by = Math.min(...b.pts.map((p) => p[1]));
            return ay - by;
        });
        let done = 0;
        for (const z of zones) {
            await this.assignFloor(z, floor);
            floor--;
            done++;
        }
        this.notification.add(`Numbered ${done} zones.`, { type: "success" });
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

    
}

registry.category("actions").add("vertikali_selector", VertikaliSelector);
