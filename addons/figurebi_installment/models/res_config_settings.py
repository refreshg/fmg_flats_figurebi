# -*- coding: utf-8 -*-
from odoo import fields, models


class ResConfigSettings(models.TransientModel):
    _inherit = "res.config.settings"

    figurebi_en_manager_id = fields.Many2one(
        "res.users", string="ინგლისურენოვანი ლიდების მენეჯერი"
    )
    figurebi_ka_manager_id = fields.Many2one(
        "res.users", string="ქართულენოვანი ლიდების მენეჯერი (default)"
    )

    def set_values(self):
        super().set_values()
        params = self.env["ir.config_parameter"].sudo()
        params.set_param("figurebi.en_manager_id", self.figurebi_en_manager_id.id or "")
        params.set_param("figurebi.ka_manager_id", self.figurebi_ka_manager_id.id or "")

    def get_values(self):
        res = super().get_values()
        params = self.env["ir.config_parameter"].sudo()
        res.update(
            figurebi_en_manager_id=int(params.get_param("figurebi.en_manager_id") or 0) or False,
            figurebi_ka_manager_id=int(params.get_param("figurebi.ka_manager_id") or 0) or False,
        )
        return res
