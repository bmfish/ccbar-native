package com.cc.service.admin;

import org.springframework.stereotype.Controller;
import org.springframework.web.bind.annotation.GetMapping;

/** 把 /admin 指到静态管理页面，避免目录路径 404。 */
@Controller
public class AdminPageController {

    @GetMapping({"/admin", "/admin/"})
    public String index() {
        return "forward:/admin/index.html";
    }
}
