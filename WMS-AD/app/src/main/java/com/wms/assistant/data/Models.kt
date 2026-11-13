package com.wms.assistant.data

data class WmsConfig(
    val baseUrl: String = "http://10.118.7.200",
    val username: String = "",
    val password: String = "",
    val pdaUserId: String = "491786087098744832",
    val warehouseOid: String = "9099134087921669",
    val barkUrl: String = ""
)

data class MaterialItem(
    val id: String,
    val name: String,
    val code: String,
    val specification: String,
    val unit: String,
    val raw: Map<String, Any?>
)

data class TaskRecord(
    val id: String,
    val createdAt: String,
    val taskCode: String,
    val taskMainId: String,
    val taskType: String,
    val status: String,
    val outStation: String,
    val trayCode: String,
    val startLocation: String,
    val raw: Map<String, Any?>
)

data class PdaTask(
    val id: String,
    val materialName: String,
    val materialNo: String,
    val specification: String,
    val quantity: String,
    val status: String
)
