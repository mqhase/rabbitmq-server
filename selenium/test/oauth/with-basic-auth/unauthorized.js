const { By, Key, until, Builder } = require('selenium-webdriver')
require('chromedriver')
const assert = require('assert')
const { buildDriver, goToHome, captureScreensFor, teardown, idpLoginPage } = require('../../utils')

const SSOHomePage = require('../../pageobjects/SSOHomePage')
const OverviewPage = require('../../pageobjects/OverviewPage')

describe('An user without management tag', function () {
  let homePage
  let idpLogin
  let overview
  let captureScreen

  before(async function () {
    driver = buildDriver()
    await goToHome(driver)
    homePage = new SSOHomePage(driver)
    idpLogin = idpLoginPage(driver)
    overview = new OverviewPage(driver)
    captureScreen = captureScreensFor(driver, __filename)

    await homePage.clickToLogin()
    await idpLogin.login('rabbit_no_management', 'rabbit_no_management')
    if (!await homePage.isLoaded()) {
      throw new Error('Failed to login')
    }
  })

  it('cannot log in into the management ui', async function () {    
    assert.ok(await homePage.isWarningVisible())
  })

  it('should get "Not authorized" warning message', async function(){
    assert.equal('Not authorized', await homePage.getWarning())
    assert.equal('Click here to logout', await homePage.getLogoutButton())
    assert.ok(await homePage.isBasicAuthSectionNotVisible())
    assert.ok(await homePage.isOAuth2SectionNotVisible())
  })

  describe("After clicking on logout button", function() {

      before(async function () {
          await homePage.clickToLogout()
      })

      it('should get redirected to home page again without error message', async function(){
        assert.ok(await homePage.isWarningNotVisible())
      })

  })


  after(async function () {
    await teardown(driver, this, captureScreen)
  })
})
