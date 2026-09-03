/** @odoo-module **/
import { registry } from "@web/core/registry";
import { dateField, DateTimeField } from "@web/views/fields/datetime/datetime_field";

const { DateTime } = luxon;

/**
 * Date field that always spells the month AND keeps the year visible,
 * e.g. "Oct 5, 2026". Odoo's stock display either drops the current year
 * (worded mode) or is fully numeric (10/05/2026) — the user wants both
 * a worded month and the year, on every date of the calculator.
 */
export class FigurebiDateField extends DateTimeField {
    getFormattedValue(valueIndex, numeric = this.props.numeric) {
        const value = this.values[valueIndex];
        if (!value) {
            return "";
        }
        if (this.field.type === "date") {
            return value.toLocaleString(DateTime.DATE_MED);
        }
        return super.getFormattedValue(valueIndex, numeric);
    }
}

export const figurebiDateField = {
    ...dateField,
    component: FigurebiDateField,
};

registry.category("fields").add("figurebi_date", figurebiDateField);
